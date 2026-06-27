# Hermetic deploy of the out-of-band push relay (ADR-0027). Exposes:
#   apps.push-relay-deploy  →  `nix run .#push-relay-deploy`   (build wasm + deploy)
#   devShells.push-relay     →  `nix develop .#push-relay`      (iterate on the worker)
#
# Both pin the whole Cloudflare-Worker-Rust toolchain so the HITL bootstrap is one
# reproducible command, not a `cargo install`/`npm i -g` tool-hunt. The deploy app
# runs from the operator workstation (it decrypts sops with &admin) — NOT a headless
# host (security constraint: the admin key never reaches an agent/headless box).
{
  pkgs,
  self,
  ...
}:
let
  # The workers-rs build pipeline: cargo → wasm32, then worker-build shells out to
  # wasm-bindgen + wasm-opt (binaryen) + esbuild (none propagated by worker-build, so
  # they are listed explicitly). gcc supplies cc/linker for host-side proc-macro builds.
  toolchain = [
    pkgs.rustc
    pkgs.cargo
    pkgs.gcc
    pkgs.worker-build
    pkgs.wasm-bindgen-cli
    pkgs.binaryen
    pkgs.esbuild
    pkgs.wrangler
    pkgs.sops
    pkgs.cacert
  ];

  # Deploy creds + keys live in the monitoring profile (vapid_private/vapid_public/
  # publish_token/cloudflare_token/cloudflare_account_id), alongside the grafana secrets.
  pushRelaySecrets = self.lib.getSecretFile "monitoring";

  deploy = pkgs.writeShellApplication {
    name = "push-relay-deploy";
    runtimeInputs = toolchain;
    text = ''
      export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"

      # Build in a writable copy of the in-repo source (the Nix store is read-only,
      # and worker-build writes worker/build + worker/target).
      SRC=$(mktemp -d)
      trap 'rm -rf "$SRC"' EXIT
      cp -r "${./.}/." "$SRC/"
      chmod -R u+w "$SRC"

      # Point deploy.sh at the sops-managed monitoring profile instead of its
      # relative-path default (vapid_*, publish_token, cloudflare_token/account_id).
      export SECRETS_FILE="${pushRelaySecrets}"

      cd "$SRC"
      exec bash ./deploy.sh "$@"
    '';
  };

  devShell = pkgs.mkShell {
    packages = toolchain;
    shellHook = ''
      export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      echo "push-relay dev shell — worker-build / wrangler / wasm-bindgen on PATH."
      echo "  cd parts/apps/push-relay/worker && worker-build --release   # build the wasm"
      echo "  nix run .#push-relay-deploy                                 # full deploy (needs sops + CF token)"
    '';
  };
in
{
  inherit deploy devShell;
}
