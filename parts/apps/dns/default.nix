{
  pkgs,
  self,
  ...
}:
let
  dnsApp = pkgs.writeShellApplication {
    name = "dns";
    runtimeInputs = [
      pkgs.dnscontrol
      pkgs.sops
      pkgs.jq
      pkgs.typescript
      pkgs.curl # fetch the authoritative mail records from Stalwart's API
      pkgs.cacert # CA bundle for verifying the Stalwart API's TLS
    ];
    text = ''
      set -euo pipefail
      export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"

      DNS_DIR=$(mktemp -d)
      CREDS_JSON=$(mktemp --suffix=.json)
      trap 'rm -rf "$DNS_DIR" "$CREDS_JSON"' EXIT

      # Copy TS config and support files
      cp "${./dnsconfig.ts}" "$DNS_DIR/dnsconfig.ts"
      cp "${./tsconfig.json}" "$DNS_DIR/tsconfig.json"
      cp "${./types-dnscontrol.d.ts}" "$DNS_DIR/types-dnscontrol.d.ts"

      NET_SECRETS="${self.lib.getSecretFile "networking"}"
      MAIL_SECRETS="${self.lib.getSecretFile "mail"}"
      SECRETS_FILE="''${SECRETS_PATH:-$NET_SECRETS}"
      DATA_FILE="$DNS_DIR/dns-data.json"
      COMMAND="''${1:-preview}"

      echo "Dumping infrastructure settings to $DATA_FILE..."
      echo '${
        builtins.toJSON {
          inherit (self.settings)
            services
            nodes
            primaryDomain
            mail
            ;
        }
      }' | jq . > "$DATA_FILE"

      MAILHOST="mail.$(jq -r .primaryDomain "$DATA_FILE")"
      mapfile -t MAIL_DOMAINS < <(jq -r '.mail.domain, (.mail.extraDomains[]?)' "$DATA_FILE")

      # ── Authoritative mail records, fetched from Stalwart's management API ──────────────
      # Stalwart owns the mail/security zone (MX, SPF, DMARC, TLSRPT, SRV, DKIM, DANE/TLSA);
      # we emit exactly what it reports so the config can't drift from the source. Fail closed:
      # an empty/failed fetch for any domain aborts rather than deleting that domain's records.
      # `check` runs offline (no secret), so it skips this and only validates our own records.
      if [ "$COMMAND" != "check" ]; then
        if [ ! -f "$MAIL_SECRETS" ]; then
          echo "Error: mail.yaml not found at $MAIL_SECRETS (needed for the Stalwart API)." >&2
          exit 1
        fi
        echo "Fetching authoritative mail records from Stalwart ($MAILHOST/api)..."
        STALWART_PW=$(sops --decrypt --extract '["stalwart_admin_password_plain"]' "$MAIL_SECRETS")
        MAIL_RECORDS='{}'
        for D in "''${MAIL_DOMAINS[@]}"; do
          recs=$(curl -fsS -m 20 -u "admin:$STALWART_PW" "https://$MAILHOST/api/dns/records/$D" 2>/dev/null \
            | jq -c '[.data[]? | {type, name, content}]' 2>/dev/null || true)
          if [ "$(printf '%s' "$recs" | jq 'length' 2>/dev/null || echo 0)" -lt 1 ]; then
            echo "ERROR: no DNS records returned for $D from $MAILHOST/api." >&2
            echo "Refusing to continue — emitting an empty mail zone would DELETE live records." >&2
            exit 1
          fi
          MAIL_RECORDS=$(printf '%s' "$MAIL_RECORDS" | jq --arg d "$D" --argjson v "$recs" '.[$d] = $v')
        done
        jq --argjson m "$MAIL_RECORDS" '.mailRecords = $m' "$DATA_FILE" > "$DATA_FILE.tmp" && mv "$DATA_FILE.tmp" "$DATA_FILE"
        echo "  fetched authoritative records for ''${#MAIL_DOMAINS[@]} mail domain(s)."
      else
        jq '.mailRecords = {}' "$DATA_FILE" > "$DATA_FILE.tmp" && mv "$DATA_FILE.tmp" "$DATA_FILE"
      fi

      echo "Compiling TypeScript configuration..."
      # We use tsc to transpile TS to ES5 JS that dnscontrol can understand.
      tsc --project "$DNS_DIR/tsconfig.json" \
          --noEmit false \
          --target ES5 \
          --module None \
          --outFile "$DNS_DIR/dnsconfig.js"

      if [[ "$COMMAND" != "check" ]]; then
        if [[ ! -f "$SECRETS_FILE" ]]; then
          echo "Error: networking.yaml not found at $SECRETS_FILE" >&2
          echo "Hint: You can override this path by setting SECRETS_PATH env var." >&2
          exit 1
        fi

        echo "Decrypting Cloudflare token from $SECRETS_FILE..."
        CLOUDFLARE_API_TOKEN=$(sops --decrypt --extract '["cloudflare_dns_token"]' "$SECRETS_FILE")
        export CLOUDFLARE_API_TOKEN

        # creds.json references the env var (literal "$CLOUDFLARE_API_TOKEN") rather than the
        # token itself, so the secret is never written to disk; dnscontrol expands it.
        jq -n '{
          "cloudflare": {
            "TYPE": "CLOUDFLAREAPI",
            "apitoken": "$CLOUDFLARE_API_TOKEN"
          }
        }' > "$CREDS_JSON"
      fi

      echo "Executing: dnscontrol check..."
      dnscontrol check --config "$DNS_DIR/dnsconfig.js"

      if [[ "$COMMAND" != "check" ]]; then
        echo "Executing: dnscontrol $COMMAND..."
        dnscontrol "$COMMAND" --config "$DNS_DIR/dnsconfig.js" --creds "$CREDS_JSON"
      fi

      if [[ "$COMMAND" == "preview" ]]; then
        echo ""
        echo "To push changes, run: nix run .#dns -- push"
      fi
    '';
  };
in
{
  type = "app";
  program = pkgs.lib.getExe dnsApp;
}
