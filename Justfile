# Simplify NixOS deployments and management

# Default: show help
default:
  @just --list

# Local rebuild and switch
switch host="":
  nh os switch . {{ if host == "" { "" } else { "--hostname " + host } }}

# Deploy to a remote host (e.g. kelpy, porcupineFish)
deploy host:
  nixos-rebuild --target-host {{host}} --sudo --ask-sudo-password switch --flake .#{{host}}

# Build the flake locally without switching
build host="":
  nh os build . {{ if host == "" { "" } else { "--hostname " + host } }}

# Run checks
check:
  nix flake check -L

# Format all Nix files
fmt:
  nix fmt

# Update flake inputs
update:
  nix flake update
