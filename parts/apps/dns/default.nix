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
      # NOT pkgs.typescript, which is now 7.x and cannot emit ES5 — see the compile step
      # below and pkgs/typescript-es5 for why that is non-negotiable here.
      self.packages.${pkgs.stdenv.hostPlatform.system}.typescript-es5
      pkgs.curl # fetch the authoritative mail records from Stalwart's API
      pkgs.cacert # CA bundle for verifying the Stalwart API's TLS
      pkgs.ssh-to-age # derive the sops age identity from the admin ssh key (see below)
    ];
    text = ''
      set -euo pipefail
      export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"

      DNS_DIR=$(mktemp -d)
      CREDS_JSON=$(mktemp --suffix=.json)
      trap 'rm -rf "$DNS_DIR" "$CREDS_JSON"' EXIT

      # ── The sops age identity ────────────────────────────────────────────────────────
      # Every `sops --decrypt` below needs the &admin age identity, and nothing on a
      # workstation supplies one any more. It used to arrive as an environment variable:
      # home-manager exported
      #   SOPS_AGE_KEY_FILE = "/run/user/$(id -u)/secrets.d/age-keys.txt";
      # and home-sops populated that file. The line left this tree in 9b785dc (2026-08-07),
      # when the homes moved to the external users flake, and home-sops has since been
      # dismantled fleet-wide (palimpsest#209) — so the variable AND the file it named are
      # both gone, and this app began failing with "no master key was able to decrypt the
      # file" on a machine where it had always worked.
      #
      # There is no fallback left to lean on, and the two obvious ones are both dead ends:
      #
      #   * sops 3.13 searches SOPS_AGE_{KEY,KEY_FILE,KEY_CMD},
      #     SOPS_AGE_SSH_PRIVATE_KEY_{FILE,CMD} and ~/.ssh/id_rsa. Note what is NOT in that
      #     list: ~/.ssh/id_ed25519, which is this fleet's admin key.
      #   * SOPS_AGE_SSH_PRIVATE_KEY_FILE does NOT substitute. That path uses age's own
      #     ssh-identity support, which opens `ssh-ed25519` recipient stanzas — whereas
      #     every file here is encrypted to a native `age1…` X25519 recipient derived with
      #     ssh-to-age (docs/adr/0003). Point it at exactly the right key and sops still
      #     answers "no identity matched any of the recipients".
      #
      # So derive the native identity here, into the tmpdir the trap above already removes.
      # Deliberately NOT a persistent ~/.config/sops/age/keys.txt: the key it would hold
      # decrypts the ENTIRE fleet, and leaving it in plaintext forever to save re-deriving
      # a few bytes per run is a bad trade.
      #
      # Skipped when an identity is already configured, so an existing setup always wins,
      # and skipped when there is no ssh key to derive from — which is the case on kelpy,
      # where the cert-renewal hook (mail/dane-autoupdate.nix) passes STALWART_PW and
      # CLOUDFLARE_API_TOKEN in from sops-nix secrets and never calls sops at all.
      ADMIN_SSH_KEY="''${HOME:-}/.ssh/id_ed25519"
      if [ -z "''${SOPS_AGE_KEY:-}''${SOPS_AGE_KEY_FILE:-}''${SOPS_AGE_KEY_CMD:-}" ] \
         && [ -n "''${HOME:-}" ] && [ -r "$ADMIN_SSH_KEY" ]; then
        SOPS_AGE_KEY_FILE="$DNS_DIR/age-key.txt"
        ( umask 077; ssh-to-age -private-key -i "$ADMIN_SSH_KEY" -o "$SOPS_AGE_KEY_FILE" )
        export SOPS_AGE_KEY_FILE
      fi

      # Copy TS config and support files
      cp "${./dnsconfig.ts}" "$DNS_DIR/dnsconfig.ts"
      cp "${./tsconfig.json}" "$DNS_DIR/tsconfig.json"
      cp "${./types-dnscontrol.d.ts}" "$DNS_DIR/types-dnscontrol.d.ts"

      NET_SECRETS="${self.lib.getSecretFile "networking"}"
      MAIL_SECRETS="${self.lib.getSecretFile "mail"}"
      SECRETS_FILE="''${SECRETS_PATH:-$NET_SECRETS}"
      DATA_FILE="$DNS_DIR/dns-data.json"
      COMMAND="''${1:-preview}"
      # Second positional arg selects the scope: "all" (default) manages the whole zone;
      # "mail" reconciles ONLY the mail/security records (DANE/TLSA, TLSRPT, DMARC, DKIM,
      # MX, SPF) and IGNOREs everything else — used by the acme cert-renewal hook.
      SCOPE="''${2:-all}"
      case "$SCOPE" in all | mail) ;; *) echo "Error: scope must be 'all' or 'mail', got '$SCOPE'" >&2; exit 1 ;; esac

      echo "Dumping infrastructure settings to $DATA_FILE (scope=$SCOPE)..."
      echo '${
        builtins.toJSON {
          inherit (self.settings)
            services
            nodes
            primaryDomain
            mail
            ;
        }
      }' | jq --arg scope "$SCOPE" '. + {scope: $scope}' > "$DATA_FILE"

      MAILHOST="mail.$(jq -r .primaryDomain "$DATA_FILE")"
      mapfile -t MAIL_DOMAINS < <(jq -r '.mail.domain, (.mail.extraDomains[]?)' "$DATA_FILE")

      # ── Authoritative mail records, fetched from Stalwart's management API ──────────────
      # Stalwart owns the mail/security zone (MX, SPF, DMARC, TLSRPT, SRV, DKIM, DANE/TLSA);
      # we emit exactly what it reports so the config can't drift from the source. Fail closed:
      # an empty/failed fetch for any domain aborts rather than deleting that domain's records.
      # `check` runs offline (no secret), so it skips this and only validates our own records.
      if [ "$COMMAND" != "check" ]; then
        # STALWART_PW may be supplied via the environment (the cert-renewal hook on kelpy
        # passes it from a sops-nix secret, so the app needs no sops key of its own).
        if [ -z "''${STALWART_PW:-}" ]; then
          if [ ! -f "$MAIL_SECRETS" ]; then
            echo "Error: mail.yaml not found at $MAIL_SECRETS (needed for the Stalwart API)." >&2
            exit 1
          fi
          STALWART_PW=$(sops --decrypt --extract '["stalwart_admin_password_plain"]' "$MAIL_SECRETS")
        fi
        echo "Fetching authoritative mail records from Stalwart ($MAILHOST/api)..."
        MAIL_RECORDS='{}'
        for D in "''${MAIL_DOMAINS[@]}"; do
          # Report mailboxes are drained by dedicated accounts, not the human
          # catch-all: DMARC (_dmarc rua/ruf) → dmarc@<domain> (dmarc-metrics-exporter),
          # and SMTP TLS Reporting (_smtp._tls rua) → tlsrpt@<domain> (monitoring-tlsrpt
          # poller). Stalwart hardcodes postmaster@<domain> in both records it suggests,
          # so we repoint each to its own mailbox here before emitting it. Scoped per
          # record name so the two rewrites never touch each other's record.
          recs=$(curl -fsS -m 20 -u "admin:$STALWART_PW" "https://$MAILHOST/api/dns/records/$D" 2>/dev/null \
            | jq -c '[.data[]?
                       | {type, name, content}
                       | if   (.name | test("_dmarc"))      then .content |= gsub("postmaster@"; "dmarc@")
                         elif (.name | test("_smtp\\._tls")) then .content |= gsub("postmaster@"; "tlsrpt@")
                         else . end
                     ]' 2>/dev/null || true)
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
      #
      # ⚠ THE ES5 TARGET IS WHY THE COMPILER IS PINNED (pkgs/typescript-es5). It is not a
      # preference that can be relaxed: dnscontrol 5.2.0 embeds otto, a strictly ES5.1
      # interpreter which — measured against the real binary — rejects `const` ("Unexpected
      # reserved word"), `let`, arrow functions ("Unexpected token >") and template literals
      # ("Unexpected token ILLEGAL"). Meanwhile `pkgs.typescript` moved to 7.x, which removed
      # the ES5 target outright along with every module kind `--outFile` accepted
      # (None/AMD/System/UMD), and reports it as a misleading "Argument for '--module' option
      # must be: …" listing a set that silently no longer contains the one being asked for.
      #
      # So do NOT "fix" a future failure here by dropping `--target`/`--module`: that
      # compiles cleanly and then fails inside dnscontrol, which is the worse failure. The
      # pin's header carries the condition under which it can go away.
      tsc --project "$DNS_DIR/tsconfig.json" \
          --noEmit false \
          --target ES5 \
          --module None \
          --outFile "$DNS_DIR/dnsconfig.js"

      if [[ "$COMMAND" != "check" ]]; then
        # CLOUDFLARE_API_TOKEN may be supplied via the environment (the cert-renewal hook on
        # kelpy passes it from a sops-nix secret); otherwise decrypt it from networking.yaml.
        if [[ -z "''${CLOUDFLARE_API_TOKEN:-}" ]]; then
          if [[ ! -f "$SECRETS_FILE" ]]; then
            echo "Error: networking.yaml not found at $SECRETS_FILE" >&2
            echo "Hint: You can override this path by setting SECRETS_PATH env var." >&2
            exit 1
          fi
          echo "Decrypting Cloudflare token from $SECRETS_FILE..."
          CLOUDFLARE_API_TOKEN=$(sops --decrypt --extract '["cloudflare_dns_token"]' "$SECRETS_FILE")
        fi
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
