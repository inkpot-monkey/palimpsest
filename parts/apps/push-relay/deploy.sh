#!/usr/bin/env bash
# Deploy the out-of-band push relay (ADR-0027). Run from the operator workstation
# (it decrypts sops with &admin) — NOT a headless host.
#
# PREFER the hermetic wrapper, which pins the whole toolchain and the sops file:
#   nix run .#push-relay-deploy        (or: just deploy-push-relay)
# This script is what that wrapper runs; invoke it directly only if you already
# have the toolchain (rust+wasm32, worker-build, wasm-bindgen, wrangler) on PATH.
#
# Prereqs (one-time HITL bootstrap, push-relay issue 01):
#   - the toolchain above (the nix wrapper supplies it)
#   - secrets/profiles/monitoring.yaml in the secrets repo, holding:
#       vapid_private          (base64url, 32-byte P-256 private key)   → Worker secret
#       vapid_public           (base64url, 65-byte P-256 public key)    → Worker var (served to PWA)
#       publish_token          (opaque bearer token rk1b presents)      → Worker secret
#       cloudflare_token       (deploy credential, "Edit Workers" scope)
#       cloudflare_account_id  (so wrangler need not prompt for the account)
#
# The SUBS KV namespace needs no setup: wrangler auto-provisions it on first deploy
# (see wrangler.toml) and reuses it thereafter.
#
# Generate a VAPID keypair once, e.g.:
#   npx web-push generate-vapid-keys   # gives base64url public + private
set -euo pipefail
cd "$(dirname "$0")"

: "${SECRETS_FILE:=${SECRETS_DIR:-../../../secrets}/profiles/monitoring.yaml}"
sops_get() { sops -d --extract "[\"$1\"]" "$SECRETS_FILE"; }

# Deploy credentials: API token + account id (account id avoids an interactive prompt).
CLOUDFLARE_API_TOKEN="$(sops_get cloudflare_token)"
CLOUDFLARE_ACCOUNT_ID="$(sops_get cloudflare_account_id)"
export CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID

echo "→ building the worker (cargo → wasm)…"
(cd worker && worker-build --release)

echo "→ pushing secrets into the Worker…"
sops_get vapid_private | wrangler secret put VAPID_PRIVATE
sops_get publish_token | wrangler secret put PUBLISH_TOKEN

# VAPID public key is not secret (the PWA fetches it) but lives in sops too, so inject
# it as a deploy-time var rather than hand-editing wrangler.toml.
echo "→ deploying…"
wrangler deploy --var "VAPID_PUBLIC:$(sops_get vapid_public)"

echo "✓ deployed. Subscribe the phone at https://push.palebluebytes.space (Add to Home Screen),"
echo "  then enable the rk1b ntfy alerter (push-relay issue 04)."
