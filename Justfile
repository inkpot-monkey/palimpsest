# Simplify NixOS deployments and management

# Default: show help
default:
  @just --list

# Local rebuild and switch
switch:
  nh os switch .

# Deploy to a remote host (e.g. kelpy, porcupineFish)
deploy host:
  nixos-rebuild --target-host {{host}} --sudo --ask-sudo-password switch --flake .#{{host}}

# Build the flake locally without switching
build host=".":
  nh os build {{host}}

# Run checks
check:
  nix build .#checks.x86_64-linux.all -L
