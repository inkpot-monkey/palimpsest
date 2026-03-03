{ pkgs, self, ... }:
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

      cp "${./palebluebytes.space.js}" "$DNS_DIR/dnsconfig.js"

      SECRETS_FILE="${self}/secrets/secrets.yaml"
      DATA_FILE="dns-data.json"

      echo "Dumping infrastructure settings to $DNS_DIR/$DATA_FILE..."
      echo '${
        builtins.toJSON {
          services = self.settings.services;
          nodes = self.settings.nodes;
        }
      }' | jq . > "$DNS_DIR/$DATA_FILE"

      if [[ ! -f "$SECRETS_FILE" ]]; then
        echo "Error: secrets.yaml not found at $SECRETS_FILE" >&2
        exit 1
      fi

      echo "Decrypting Cloudflare token..."
      TOKEN=$(sops --decrypt --extract '["cloudflare_dns_token"]' "$SECRETS_FILE")

      CREDS_JSON=$(mktemp --suffix=.json)
      trap 'rm -f "$CREDS_JSON"' EXIT

      # Secure JSON construction
      jq -n --arg token "$TOKEN" '{
        "cloudflare": {
          "TYPE": "CLOUDFLAREAPI",
          "apitoken": $token
        }
      }' > "$CREDS_JSON"

      COMMAND="''${1:-preview}"

      echo "Executing: dnscontrol check..."
      dnscontrol check --config "$DNS_DIR/dnsconfig.js"

      echo "Executing: dnscontrol $COMMAND..."
      dnscontrol "$COMMAND" --config "$DNS_DIR/dnsconfig.js" --creds "$CREDS_JSON"

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
