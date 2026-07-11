# Regression check for the "Operator read" helper (users/inkpotmonkey/home/secret.nix).
# Pure-derivation (no VM): mints a throwaway age key, encrypts a fixture with sops, and
# asserts the key->extract logic. Guards the dotted-key regression specifically — the
# original `.`->`/` rewrite made `apikey@api.example.com` unreachable. Also proves `-l`
# lists structure without decrypting a value, and that bad invocations exit nonzero.
{ pkgs, self, ... }:
let
  secret = import "${self}/users/inkpotmonkey/home/secret.nix" {
    inherit pkgs;
    username = "tester";
    homeDirectory = "/home/tester";
  };

  # Plaintext fixture: a flat key, a nested map, and a dotted top-level key (the one
  # the regression made unreachable). writeText sidesteps heredoc-in-Nix indentation.
  fixture = pkgs.writeText "tester.yaml" ''
    flat: flat-value
    cloudflare:
      api_token: nested-value
    apikey@api.example.com: dotted-value
  '';
in
pkgs.runCommand "secret-read-test"
  {
    nativeBuildInputs = [
      pkgs.sops
      pkgs.age
      pkgs.yq-go
      secret
    ];
  }
  ''
    set -euo pipefail
    export HOME="$TMPDIR"

    # Ephemeral age identity + recipient, entirely offline (sandbox has no network).
    age-keygen -o "$TMPDIR/key.txt" 2>/dev/null
    recipient="$(age-keygen -y "$TMPDIR/key.txt")"
    export SOPS_AGE_KEY_FILE="$TMPDIR/key.txt"

    store="$TMPDIR/store"
    mkdir -p "$store/users"
    cp ${fixture} "$store/users/tester.yaml"
    chmod +w "$store/users/tester.yaml"
    sops --encrypt --age "$recipient" --in-place "$store/users/tester.yaml"
    export SECRET_STORE_DIR="$store"

    # --- extract logic (the part that has silently broken before) ---
    [ "$(secret flat)" = "flat-value" ]                    || { echo "FAIL: flat extract"; exit 1; }
    [ "$(secret cloudflare/api_token)" = "nested-value" ]  || { echo "FAIL: nested extract"; exit 1; }
    [ "$(secret apikey@api.example.com)" = "dotted-value" ] || { echo "FAIL: dotted-key regression"; exit 1; }

    # --- -l lists keys from ciphertext: masks values, keeps structure, hides sops meta ---
    list="$(secret -l)"
    echo "$list" | grep -qE '^flat:.*\*\*\*'     || { echo "FAIL: -l flat key"; exit 1; }
    echo "$list" | grep -qE 'api_token:.*\*\*\*' || { echo "FAIL: -l nested key"; exit 1; }
    if echo "$list" | grep -q 'nested-value'; then echo "FAIL: -l leaked a plaintext value"; exit 1; fi
    if echo "$list" | grep -q '^sops:';       then echo "FAIL: -l leaked sops metadata"; exit 1; fi

    # --- bad invocations exit nonzero (guarded by `if` so set -e tolerates the failure) ---
    if secret -z 2>/dev/null; then echo "FAIL: unknown flag should exit nonzero"; exit 1; fi
    if secret 2>/dev/null;    then echo "FAIL: missing key should exit nonzero"; exit 1; fi
    if secret -f 2>/dev/null;  then echo "FAIL: -f without arg should exit nonzero"; exit 1; fi

    echo "secret-read: all assertions passed"
    touch "$out"
  ''
