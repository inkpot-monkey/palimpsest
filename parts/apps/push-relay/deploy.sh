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
#   - secrets/profiles/push-relay.yaml in the secrets repo, holding:
#       vapid_private        (base64url, 32-byte P-256 private key)
#       publish_token        (opaque bearer token rk1b presents)
#       cloudflare_api_token (deploy credential)
#   - wrangler.toml filled: KV namespace id + VAPID_PUBLIC
#
# Generate a VAPID keypair once, e.g.:
#   npx web-push generate-vapid-keys   # gives base64url public + private
set -euo pipefail
cd "$(dirname "$0")"

: "${SECRETS_FILE:=${SECRETS_DIR:-../../../secrets}/profiles/push-relay.yaml}"
sops_get() { sops -d --extract "[\"$1\"]" "$SECRETS_FILE"; }

CLOUDFLARE_API_TOKEN="$(sops_get cloudflare_api_token)"
export CLOUDFLARE_API_TOKEN

echo "→ building the worker (cargo → wasm)…"
(cd worker && worker-build --release)

echo "→ pushing secrets into the Worker…"
sops_get vapid_private | wrangler secret put VAPID_PRIVATE
sops_get publish_token | wrangler secret put PUBLISH_TOKEN

echo "→ deploying…"
wrangler deploy

echo "✓ deployed. Subscribe the phone at https://push.palebluebytes.space (Add to Home Screen),"
echo "  then enable the rk1b ntfy alerter (push-relay issue 04)."
