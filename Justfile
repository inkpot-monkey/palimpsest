# Simplify NixOS deployments and management

# Default: show help
default:
  @just --list

# Local rebuild and switch
switch host="":
  nh os switch . --no-nom {{ if host == "" { "" } else { "--hostname " + host } }}

# SSH options forwarded (via NIX_SSHOPTS) to every ssh/nix-copy nixos-rebuild spawns.
# Tolerate ~120s of dead air (20s x 6) before the control connection is torn down, so a
# brief blip/roam during a deploy doesn't abort it. Deploy over Tailscale (bare hostname,
# MagicDNS) for stable transport; these opts stop a momentary drop from killing the session.
# Activation itself runs detached in a systemd-run unit on the target (nixos-rebuild-ng),
# so it completes regardless.
ssh_opts := "-o ServerAliveInterval=20 -o ServerAliveCountMax=6 -o ConnectTimeout=10"

# Most targets enable passwordless wheel sudo (custom.profiles.sudo) so deploys are
# non-interactive. kelpy is the public-facing VPS and keeps its sudo password, so the
# recipes add --ask-sudo-password for it (prompted once, up front, before activation).

# Deploy to a remote host (e.g. kelpy, porcupineFish)
deploy host:
		NIX_SSHOPTS="{{ssh_opts}}" nixos-rebuild --target-host {{host}} --sudo {{ if host == "kelpy" { "--ask-sudo-password" } else { "" } }} switch --flake .#{{host}}

# Deploy to a remote host and set as default for next boot
deployBoot host:
		NIX_SSHOPTS="{{ssh_opts}}" nixos-rebuild --target-host {{host}} --sudo {{ if host == "kelpy" { "--ask-sudo-password" } else { "" } }} boot --flake .#{{host}}

# Build the flake locally without switching
build host="":
  nh os build . --no-nom {{ if host == "" { "" } else { "--hostname " + host } }}

# Push a host's kernel outputs (out/dev/modules) to palebluebytes.cachix.org.
# nixos-raspberrypi.cachix.org caches ONLY the kernel's `out` output; a normal system
# closure also needs `dev`+`modules` (uncached), so after a GC the next deploy recompiles
# the whole kernel from source on the rk1b builder (~tens of min). Pushing all three to our
# own cache makes future deploys substitute them. Re-run after any kernel-pin bump.
# Needs a write token: `export CACHIX_AUTH_TOKEN=...` (or `cachix authtoken <tok>`) first.
cache-kernel host="porcupineFish":
  #!/usr/bin/env bash
  set -euo pipefail
  paths=$(nix eval --no-eval-cache --raw --impure --expr \
    'let k = (builtins.getFlake (toString ./.)).nixosConfigurations.{{host}}.config.boot.kernelPackages.kernel;
     in builtins.concatStringsSep "\n" (map (o: k.${o}.outPath) k.outputs)')
  echo "kernel outputs for {{host}}:"; echo "$paths"
  # The deploy builds these on the rk1b aarch64 builder; pull any that aren't local yet.
  for p in $paths; do
    nix path-info "$p" >/dev/null 2>&1 || { echo "copying $p from rk1b"; nix copy --from ssh-ng://inkpotmonkey@rk1b "$p"; }
  done
  echo "$paths" | xargs cachix push palebluebytes

# Run checks
check:
  nix flake check -L

# Run dry-run checks for all hosts
check-all:
  @nix flake show --json . 2>/dev/null | jq -r '.nixosConfigurations | keys[]' | xargs -I{} sh -c 'echo "Checking host: {}" && nixos-rebuild dry-run --flake .#{}'

# DNS management with DnsControl (commands: preview, push, check)
dns command="preview":
  nix run .#dns -- {{command}}

# Deploy the out-of-band push relay to Cloudflare (ADR-0020). Hermetic: pins the
# wasm toolchain + wrangler, reads vapid_private/publish_token/cloudflare_api_token
# from sops. Run from the operator workstation (holds &admin) — NOT a headless host.
deploy-push-relay:
  nix run .#push-relay-deploy

# Print the sops recipients implied by the feature grants — the single source of
# truth (contract ADR-0001 slice 06). Each secret-bearing feature's stash file should be
# encrypted to EXACTLY these hosts: `{ "<file>" = [ "<host>" ... ]; }`.
sops-recipients:
  @nix eval --json '.#lib.featureRecipients' | jq .

# Re-key / revoke procedure (TRUSTED MACHINE — uses the admin key; operates on the
# stash at $SECRETS_DIR). The recipient set is *derived*, never hand-maintained:
#   re-key:  `just sops-recipients` -> set each file's creation_rule in
#            stash/.sops.yaml to those hosts (+ &admin) -> `sops updatekeys -y <file>`
#            -> commit+push stash -> `nix flake update secrets`.
#   revoke:  drop the host from the file's recipients as above, AND ROTATE the secret
#            (the host has already seen the cleartext) — generate a new value and
#            `sops <file>` to replace it, then re-key and redeploy.
#   drift:   `just sops-recipients` must match stash/.sops.yaml; a mismatch means a
#            grant changed without a re-key (or vice versa).

# Fast local Grafana preview loop for iterating on the in-tree dashboards.
# Runs a throwaway Grafana pointed at rk1b's live VictoriaMetrics/VictoriaLogs
# over Tailscale, provisioning modules/nixos/profiles/monitoring/dashboards/*.json
# for editing — no deploy-to-rk1b round trip. Open http://127.0.0.1:3001.
grafana-preview:
  modules/nixos/profiles/monitoring/dashboards/preview.sh

# Format all Nix files
fmt:
  nix fmt

# Update flake inputs
update:
  nix flake update
