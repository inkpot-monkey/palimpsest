{
  pkgs,
  self,
  inputs,
  ...
}:
let
  dnsApp = pkgs.writeShellApplication {
    name = "dns";
    runtimeInputs = [
      pkgs.dnscontrol
      pkgs.sops
      pkgs.jq
    ];
    text = ''
      set -euo pipefail

      # Create a temporary working directory to keep config and data together
      DNS_DIR=$(mktemp -d)
      trap 'rm -rf "$DNS_DIR"' EXIT

      # Copy JS config
      cp "${./dnsconfig.js}" "$DNS_DIR/dnsconfig.js"

      # Fallback to local secrets directory if SECRETS_PATH is not set
      DEFAULT_SECRETS="${../../../secrets}/profiles/networking.yaml"
      SECRETS_FILE="''${SECRETS_PATH:-$DEFAULT_SECRETS}"
      DATA_FILE="$DNS_DIR/dns-data.json"

      echo "Dumping infrastructure settings to $DATA_FILE..."
      echo '${
        builtins.toJSON {
          inherit (self.settings) services;
          inherit (self.settings) nodes;
          inherit (self.settings) primaryDomain mailDomain;
        }
      }' | jq . > "$DATA_FILE"

      COMMAND="''${1:-preview}"

      if [[ "$COMMAND" != "check" ]]; then
        if [[ ! -f "$SECRETS_FILE" ]]; then
          echo "Error: networking.yaml not found at $SECRETS_FILE" >&2
          echo "Hint: You can override this path by setting SECRETS_PATH env var." >&2
          exit 1
        fi

        echo "Decrypting Cloudflare token from $SECRETS_FILE..."
        TOKEN=$(sops --decrypt --extract '["cloudflare_dns_token"]' "$SECRETS_FILE")

        CREDS_JSON=$(mktemp --suffix=.json)
        trap 'rm -f "$CREDS_JSON"' EXIT

        # Secure JSON construction using jq to avoid shell injection
        jq -n --arg token "$TOKEN" '{
          "cloudflare": {
            "TYPE": "CLOUDFLAREAPI",
            "apitoken": $token
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
