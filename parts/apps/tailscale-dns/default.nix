{
  pkgs,
  self,
  ...
}:
# `nix run .#tailscale-dns -- [get|preview|push]`
#
# Manages the tailnet's GLOBAL NAMESERVERS (the admin-console DNS list) via the
# Tailscale HTTP API, so the drift-prone step ADR-0023 called out — "after a
# reflash, re-enter the nameserver IP by hand" — becomes one command instead.
#
# The nameserver hosts are declared once in `settings.dns.nameserverHosts`
# (= the fleet's blocky resolvers, kelpy + rk1b). This app resolves each host's
# CURRENT tailscale IP live (`tailscale ip -4 <host>`, via the operator's own
# tailscaled netmap) and POSTs the list — which REPLACES it, so any stale/drifted
# entry (e.g. the dead porcupineFish `100.107.42.51`) is dropped in the same call.
#
# NOT managed here: the "Override local DNS" toggle. The API exposes only
# `magicDNS`, not that toggle (a known gap), so it stays a one-time console
# setting — keep it ON (ADR-0023) so the unmanaged phone gets ad-block.
#
# Auth is the FLEET's Tailscale API key (profiles/networking.yaml → tailscale_dns_api_key),
# decrypted at runtime and passed to curl via a config on STDIN (`-K -`) — never on the
# command line (would show in `ps`) nor written to disk. It lives in a fleet file so no
# fleet tooling reads a user secret (consumption purity, ADR-0025). It is still a personal
# access token (`tskey-api-…`) usable as a Bearer directly; TODO(2026-10-05): at the
# token's forced rotation, re-mint it as a fleet-owned OAuth client (DNS scope) to also cut
# the user-login provenance — which adds a token-exchange step before the Bearer call.
let
  inherit (pkgs) lib;

  # The default tailnet of the API key. Using "-" avoids hardcoding the org name.
  tailnet = "-";
  nameserverHosts = self.settings.dns.nameserverHosts;

  app = pkgs.writeShellApplication {
    name = "tailscale-dns";
    runtimeInputs = [
      pkgs.tailscale # live peer-IP resolution from the local netmap
      pkgs.curl
      pkgs.jq
      pkgs.sops # decrypt the API key at runtime
      pkgs.cacert # CA bundle so curl can verify api.tailscale.com
    ];
    text = ''
      set -euo pipefail
      export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"

      API="https://api.tailscale.com/api/v2/tailnet/${tailnet}/dns/nameservers"
      COMMAND="''${1:-preview}"
      HOSTS=(${lib.concatStringsSep " " (map lib.escapeShellArg nameserverHosts)})

      # ── Resolve each fleet DNS resolver's CURRENT tailscale IP ────────────────────
      # Live resolution (not the static secrets/nodes.nix IPs) is what makes this
      # self-healing: a reflash drifts the IP but `tailscale ip -4` always reports the
      # real current one. Refuse to build a PARTIAL list — dropping a resolver would
      # silently halve DNS redundancy (the same trap the blocky generator guards).
      DNS_JSON='[]'
      for h in "''${HOSTS[@]}"; do
        ip="$(tailscale ip -4 "$h" 2>/dev/null | head -n1 || true)"
        if [ -z "$ip" ]; then
          echo "ERROR: could not resolve a tailscale IP for '$h'." >&2
          echo "Are you on the tailnet, and is '$h' up? Refusing to push a partial" >&2
          echo "nameserver list." >&2
          exit 1
        fi
        printf '  %-16s -> %s\n' "$h" "$ip"
        DNS_JSON="$(jq -c --arg ip "$ip" '. + [$ip]' <<<"$DNS_JSON")"
      done

      # ── Auth: decrypt the fleet's tailscale API key, keep it off ps + disk ─────
      FLEET_SECRETS="${self.lib.getSecretPath "profiles/networking.yaml"}"
      TS_API_KEY="$(sops --decrypt --extract '["tailscale_dns_api_key"]' "$FLEET_SECRETS")"
      # `auth` emits a curl config line consumed via `-K -` (stdin), so the key never
      # appears in the process table or on disk. The request BODY (plain IPs) is not
      # secret, so it rides the normal `-d` flag.
      auth() { printf 'header = "Authorization: Bearer %s"\n' "$TS_API_KEY"; }

      CURRENT="$(auth | curl -fsS -K - "$API" | jq -c '.dns')"
      echo "current  nameservers: $CURRENT"
      echo "computed nameservers: $DNS_JSON"

      case "$COMMAND" in
        get) ;;
        preview)
          if [ "$CURRENT" = "$DNS_JSON" ]; then
            echo "✓ already up to date."
          else
            echo ""
            echo "To apply, run: nix run .#tailscale-dns -- push"
          fi
          ;;
        push)
          BODY="$(jq -nc --argjson dns "$DNS_JSON" '{dns: $dns}')"
          auth | curl -fsS -K - -X POST \
            -H 'Content-Type: application/json' \
            -d "$BODY" "$API" >/dev/null
          echo "✓ pushed — global nameservers replaced with: $DNS_JSON"
          echo "  (Any stale/drifted entry is now gone. 'Override local DNS' is a"
          echo "   one-time console toggle, not managed here — keep it ON.)"
          ;;
        *)
          echo "usage: nix run .#tailscale-dns -- [get|preview|push]" >&2
          exit 1
          ;;
      esac
    '';
  };
in
{
  type = "app";
  program = pkgs.lib.getExe app;
}
