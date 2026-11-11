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

  # Shared delivery (modules/shared/alert-post.nix), replacing a hand-rolled curl that this
  # module was the last holdout on. It brings retry-on-connection-refused, which is the
  # specific failure recorded here four times: the alert fires exactly when hookshot is most
  # likely to be mid-restart, because a cert rotation and a deploy are the same moment.
  alertPost = import (self + "/modules/shared/alert-post.nix") { inherit lib pkgs; };
  certFile = "/var/lib/acme/mail.${mailCfg.domain}/cert.pem";

  # The cert Stalwart PRESENTS, not the one on disk. Implicit TLS, so no -starttls; 993 is
  # Stalwart's imaps listener and serves the same cert as 25/465.
  servedPort = 993;

  syncScript = pkgs.writeShellScript "mail-dane-sync" ''
    set -uo pipefail
    # Feed the dns app its creds from the environment (the app skips its own sops decrypt
    # when these are set). The CF token reused here is the ACME DNS-01 token (Zone.DNS:Edit),
    # which is exactly the scope dnscontrol needs.
    export CLOUDFLARE_API_TOKEN="$(cat ${config.sops.secrets.cloudflare_dns_token_stalwart.path})"
    export STALWART_PW="$(cat ${config.sops.secrets.stalwart_admin_password_plain.path})"
    ${alertPost.mkPost {
      name = "mail-dane-sync";
      inherit (cfg) webhookUrlFile;
      outOfBand = alertPost.oobFromWatcher config;
    }}

    # WAIT FOR STALWART TO ACTUALLY SERVE THE NEW CERT BEFORE READING ANYTHING.
    #
    # This unit does not hash the cert file itself — it asks Stalwart's management API for
    # the authoritative records, and Stalwart derives its TLSA from the cert it has LOADED.
    # So running while Stalwart still holds the previous cert does not merely delay the
    # push: it publishes TLSA for the OLD cert and then reports "0 corrections", which is
    # indistinguishable from success. That is exactly what happened on 2026-11-11 — the
    # first successful renewal in months pushed fingerprints for the superseded cert.
    #
    # The path unit fires on the cert write, and security.acme restarts Stalwart with
    # `systemctl --no-block`, so the two race by design and no After= can order them (they
    # are separate transactions). Hence verify rather than order: poll the live listener
    # until what it presents matches what is on disk.
    want="$(${pkgs.openssl}/bin/openssl x509 -in ${certFile} -outform DER \
      | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)"
    deadline=$(( $(${pkgs.coreutils}/bin/date +%s) + ${toString cfg.certReloadTimeoutSec} ))
    while :; do
      got="$(${pkgs.coreutils}/bin/timeout 10 ${pkgs.openssl}/bin/openssl s_client \
        -connect 127.0.0.1:${toString servedPort} -servername mail.${mailCfg.domain} \
        </dev/null 2>/dev/null \
        | ${pkgs.openssl}/bin/openssl x509 -outform DER 2>/dev/null \
        | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)"
      [ "$got" = "$want" ] && break
      if [ "$(${pkgs.coreutils}/bin/date +%s)" -ge "$deadline" ]; then
        # Fail rather than push. Stale-but-red beats wrong-and-green: a bad TLSA breaks
        # inbound mail from DANE-enforcing senders the moment the zones are signed, and the
        # failed unit state is what node-exporter publishes (see the exit rationale below).
        post "⚠️ [dane] mail cert renewed but Stalwart is still serving the OLD cert after ${toString cfg.certReloadTimeoutSec}s — NOT pushing TLSA (they would describe the superseded cert). Check 'systemctl status stalwart' and security.acme reloadServices."
        exit 1
      fi
      ${pkgs.coreutils}/bin/sleep 5
    done

    out="$(${dnsProgram} push mail 2>&1)"; rc=$?
    printf '%s\n' "$out"

    # dnscontrol prints a final "Done. N corrections." — 0 means already in sync (stay quiet).
    n="$(printf '%s\n' "$out" | ${pkgs.gnugrep}/bin/grep -oE 'Done\. [0-9]+ correction' | ${pkgs.gnugrep}/bin/grep -oE '[0-9]+' | tail -1)"

    if [ "$rc" -ne 0 ]; then
      post "⚠️ [dane] mail cert renewed but the DANE/TLSA DNS sync FAILED (rc=$rc) — records may be stale; check 'journalctl -u mail-dane-sync'."
      # AND FAIL THE UNIT. This used to `exit 0` unconditionally, on the reasoning that the
      # path watcher would retry on the next cert change and a hard failure would only spam
      # the journal. That reasoning does not survive contact with the retry interval: the
      # next cert change is ~60 DAYS away, so a persistent breakage sits undetected for two
      # months while systemd cheerfully logs "Finished Reconcile mail DANE/TLSA DNS records".
      #
      # It is not hypothetical — it is how this was found. A TypeScript bump broke the dns
      # app's compile step; the reconcile failed, its alert landed in a hookshot restart
      # window and was dropped, and the unit reported success. Three failures in a row and
      # nothing anywhere was red.
      #
      # A non-zero exit leaves the unit `failed`, which node-exporter's systemd collector
      # already publishes as node_systemd_unit_state{state="failed"} — so the state is
      # observable even when the notification is not. That is the whole point: the alert is
      # best-effort, the unit state is not.
      exit "$rc"
    fi

    if [ -n "''${n:-}" ] && [ "$n" != "0" ]; then
      post "🔐 [dane] mail cert renewed → pushed $n DNS correction(s) to keep DANE/TLSA in sync with the new cert."
    fi

    # A push that SUCCEEDED but whose alert could not be delivered still exits 0: the records
    # are correct, which is what this unit exists for, and `post` has already logged and
    # tried its out-of-band leg. Only a failed reconcile fails the unit.
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

    certReloadTimeoutSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 180;
      description = ''
        How long to wait for Stalwart to serve the cert that acme has just written before
        giving up and failing the reconcile. Covers a `reloadServices` restart of Stalwart,
        which on a loaded mail host is seconds, not minutes — the margin is for the case
        where the restart queues behind an in-flight ingest.
      '';
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
      # hookshot is the in-band alert path, and it lives on this host. Ordering against it
      # does not fix a mid-run restart (nothing can), but it does stop the common boot-time
      # case where the reconcile fires before hookshot has opened its port at all.
      after = [
        "network-online.target"
        "matrix-hookshot.service"
      ];
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
