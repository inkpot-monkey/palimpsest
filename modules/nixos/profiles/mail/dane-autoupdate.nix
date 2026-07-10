# Keep the mail domains' DANE/TLSA (and the rest of Stalwart's authoritative mail/security
# records) in sync with the live cert. security.acme rotates the mail cert (a fresh key each
# renewal → new TLSA fingerprints); without a push the published TLSA goes stale. Today that
# is harmless — the zones are not DNSSEC-signed, so senders ignore DANE — but it is a latent
# footgun: enabling DNSSEC under a manual-push regime would let the next renewal break
# inbound mail from DANE-enforcing senders.
#
# Mechanism: a systemd.path watches the mail cert file; on any change (i.e. a renewal) it
# runs the `dns` app in "mail" scope, which reconciles ONLY the mail/security records
# (DANE/TLSA, TLSRPT, DMARC, DKIM, MX, SPF) and IGNOREs every other record in the zone — so
# it can never touch service A/AAAA records. Runs as root on the mail host (kelpy) so it can
# read both secrets; the dns app takes CLOUDFLARE_API_TOKEN + STALWART_PW from the
# environment, so it needs no sops key of its own. A non-empty reconcile pings #infra-alerts.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:

let
  cfg = config.custom.profiles.mail-dane-autoupdate;
  mailCfg = config.custom.profiles.mail;

  # Reuse the dns app's exe (same source of truth as a manual `nix run .#dns` push, so the
  # automated and manual reconciles can never compute a different record set).
  dnsProgram = (import (self + "/parts/apps/dns") { inherit pkgs self; }).program;
  certFile = "/var/lib/acme/mail.${mailCfg.domain}/cert.pem";

  syncScript = pkgs.writeShellScript "mail-dane-sync" ''
    set -uo pipefail
    # Feed the dns app its creds from the environment (the app skips its own sops decrypt
    # when these are set). The CF token reused here is the ACME DNS-01 token (Zone.DNS:Edit),
    # which is exactly the scope dnscontrol needs.
    export CLOUDFLARE_API_TOKEN="$(cat ${config.sops.secrets.cloudflare_dns_token_stalwart.path})"
    export STALWART_PW="$(cat ${config.sops.secrets.stalwart_admin_password_plain.path})"
    url="$(cat ${lib.escapeShellArg cfg.webhookUrlFile} 2>/dev/null || true)"

    out="$(${dnsProgram} push mail 2>&1)"; rc=$?
    printf '%s\n' "$out"

    # dnscontrol prints a final "Done. N corrections." — 0 means already in sync (stay quiet).
    n="$(printf '%s\n' "$out" | ${pkgs.gnugrep}/bin/grep -oE 'Done\. [0-9]+ correction' | ${pkgs.gnugrep}/bin/grep -oE '[0-9]+' | tail -1)"

    if [ "$rc" -ne 0 ]; then
      msg="⚠️ [dane] mail cert renewed but the DANE/TLSA DNS sync FAILED (rc=$rc) — records may be stale; check 'journalctl -u mail-dane-sync'."
    elif [ -n "''${n:-}" ] && [ "$n" != "0" ]; then
      msg="🔐 [dane] mail cert renewed → pushed $n DNS correction(s) to keep DANE/TLSA in sync with the new cert."
    else
      msg=""
    fi

    if [ -n "$msg" ]; then
      if [ -n "$url" ]; then
        ${pkgs.curl}/bin/curl -sS -m 10 -o /dev/null -H 'content-type: application/json' \
          --data "$(${pkgs.jq}/bin/jq -nc --arg t "$msg" '{text:$t}')" "$url" \
          || echo "mail-dane-sync: failed to POST alert" >&2
      else
        echo "mail-dane-sync: webhook url unavailable; would have posted: $msg" >&2
      fi
    fi
    # Never fail the unit on a transient push/alert problem — the path watcher will retry on
    # the next cert change, and a hard failure would just spam the journal.
    exit 0
  '';
in
{
  options.custom.profiles.mail-dane-autoupdate = {
    enable = lib.mkEnableOption ''
      auto-reconciling the mail domains' DANE/TLSA (and other Stalwart-authoritative) DNS
      records whenever security.acme renews the mail cert. Enable on the mail host (kelpy),
      alongside custom.profiles.mail.
    '';

    webhookUrlFile = lib.mkOption {
      type = lib.types.path;
      default = config.custom.profiles.matrix.infraAlerts.webhookUrlFile;
      defaultText = lib.literalExpression "config.custom.profiles.matrix.infraAlerts.webhookUrlFile";
      description = "File holding the #infra-alerts hookshot webhook url a non-empty reconcile posts to.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = mailCfg.enable;
        message = "custom.profiles.mail-dane-autoupdate requires custom.profiles.mail.enable (it reconciles that mail server's records).";
      }
    ];

    # Plaintext Stalwart admin password for the management API (Basic auth). Lives in
    # mail.yaml next to the hashed one; root-only (the sync service runs as root).
    sops.secrets.stalwart_admin_password_plain = {
      sopsFile = self.lib.getSecretPath "profiles/mail.yaml";
    };

    systemd.services.mail-dane-sync = {
      description = "Reconcile mail DANE/TLSA DNS records with the renewed cert";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = syncScript;
      };
    };

    # Fire the reconcile when acme rewrites the cert (renewal). PathChanged does not
    # retrigger for a pre-existing file at boot, so this only runs on an actual rotation;
    # a manual run is `systemctl start mail-dane-sync`.
    systemd.paths.mail-dane-sync = {
      description = "Watch the mail cert and resync DANE/TLSA on renewal";
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = certFile;
        Unit = "mail-dane-sync.service";
      };
    };
  };
}
