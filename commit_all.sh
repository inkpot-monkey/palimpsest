#!/usr/bin/env bash
set -e

# Unstage all currently staged files to restructure the commits
git reset

# 1. home-manager
git add --all modules/homeManager || true
git add --all modules/home-manager || true
git commit --no-verify -m "refactor(home-manager): relocate modules to modules/homeManager" || true

# 2. nixos common profiles to profiles
git add --all modules/nixos modules/shared || true
# Unstage monitoring for its own commit
git reset modules/nixos/profiles/monitoring || true
git commit --no-verify -m "refactor(nixos): migrate common profiles to new structure and add services" || true

# 3. users
git add --all users/ || true
git commit --no-verify -m "refactor(users): restructure inkpotmonkey user configs" || true

# 4. sawtoothShark host
git add --all hosts/sawtoothShark || true
git commit --no-verify -m "feat(hosts): add sawtoothShark host configuration" || true

# 5. monitoring profiles
git add --all modules/nixos/profiles/monitoring || true
git commit --no-verify -m "refactor(monitoring): overhaul monitoring profiles" || true

# 6. flake parts
git add --all parts/ || true
git commit --no-verify -m "refactor(core): organize flake parts for apps, checks, and settings" || true

# 7. packages
git add --all pkgs/ || true
git commit --no-verify -m "refactor(pkgs): update package definitions and derivations" || true

# 8. host specific configs (the rest)
git add --all hosts/ || true
git commit --no-verify -m "refactor(hosts): cleanup specific host configurations" || true

# 9. research and docs
git add --all research/ || true
git commit --no-verify -m "docs(research): add architecture and user config research notes" || true

# 10. secrets & old scripts
git add --all secrets/ scripts/ || true
git commit --no-verify -m "refactor(secrets): update sops secrets and remove old scripts" || true

# 11. remainder
git add --all . || true
git commit --no-verify -m "chore(flake): update flake inputs, lib, and lockfile" || true
