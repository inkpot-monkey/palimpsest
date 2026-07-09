# ESPHome firmware for the smart bulbs

Per-bulb ESPHome configs for the Antela WiFi bulbs, flashed via tuya-cloudcutter.
This directory is the **source of truth** for the bulb firmware. Design rationale
and the rejected alternatives (Tuya cloud, `tuya_local`, OpenBeken/MQTT) are in
[`../docs/adr/0015-bulbs-run-esphome-via-cloudcutter.md`](../docs/adr/0015-bulbs-run-esphome-via-cloudcutter.md).

Firmware is built with the `esphome` CLI **outside** the nix sandbox, because
LibreTiny/PlatformIO downloads its toolchain at build time (so a hermetic nix
derivation is not used — see ADR-0015).

For the full end-to-end procedure (flashing a bulb from stock, adopting it in HA,
adding the light), see the runbook:
[`docs/runbooks/antela-bulbs-esphome.md`](../docs/runbooks/antela-bulbs-esphome.md).

## Layout

- `<node-name>.yaml` — one committed config per bulb (tracked).
- `secrets.yaml` — the decrypted build secrets (**gitignored**, ephemeral).
- `secrets.yaml.example` — the keys `secrets.yaml` must provide.

## Secrets

The real secrets live sops-encrypted in stash at `secrets/profiles/esphome.yaml`
(the WiFi PSK reused from `secrets/profiles/wireless.yaml`, plus a per-bulb API
encryption key and OTA password). They are consumed only by the `esphome` CLI on
your trusted dev box, never by a NixOS service — so there is no `sops.secrets`
wiring for them.

Seed the stash file once (on the machine that holds the admin key):

```sh
# from the stash checkout (the repo's secrets/ working copy)
$EDITOR profiles/esphome.yaml         # populated per secrets.yaml.example
sops --encrypt --in-place profiles/esphome.yaml
git add profiles/esphome.yaml && git commit -m "feat(esphome): bulb build secrets" && git push
# then, back in the nixos repo, relock so the input sees it:
nix flake update secrets
```

Generate per-bulb values with:

```sh
openssl rand -base64 32   # api key (ESPHome native-API noise PSK)
openssl rand -hex 16      # ota password
```

## Build & flash flow

```sh
# 1. Decrypt the build secrets into this directory (ephemeral, gitignored).
sops -d secrets/profiles/esphome.yaml > esphome/secrets.yaml   # from the nixos repo root

# 2. First flash: build the firmware, then push it OTA via tuya-cloudcutter
#    (see issues 01 and 04 — cloudcutter handles the initial stock->ESPHome flash).
nix run nixpkgs#esphome -- compile esphome/<node-name>.yaml

# 3. Subsequent changes: OTA, no cloudcutter needed.
nix run nixpkgs#esphome -- run esphome/<node-name>.yaml

# Sanity-check that all !secret references resolve:
nix run nixpkgs#esphome -- config esphome/<node-name>.yaml
```
