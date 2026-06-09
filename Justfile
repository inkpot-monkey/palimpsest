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

# Run checks
check:
  nix flake check -L

# Run dry-run checks for all hosts
check-all:
  @nix flake show --json . 2>/dev/null | jq -r '.nixosConfigurations | keys[]' | xargs -I{} sh -c 'echo "Checking host: {}" && nixos-rebuild dry-run --flake .#{}'

# DNS management with DnsControl (commands: preview, push, check)
dns command="preview":
  nix run .#dns -- {{command}}

# Format all Nix files
fmt:
  nix fmt

# Update flake inputs
update:
  nix flake update
