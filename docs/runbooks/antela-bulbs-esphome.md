# Runbook: Antela A60 bulbs → Home Assistant (ESPHome via cloudcutter)

How to bring an Antela Filament A60 WiFi bulb under local Home Assistant control by flashing ESPHome onto it with tuya-cloudcutter. Decision rationale and rejected alternatives are in [ADR-0015](../adr/0015-bulbs-run-esphome-via-cloudcutter.md); the per-bulb config lives in [`esphome/`](../../esphome/); work is tracked in `.scratch/antela-bulbs/` (local, gitignored).

## The shape of it

Two **independent repo tasks** (do anytime) plus a **per-bulb pipeline**. The pipeline has a chicken-and-egg quirk: cloudcutter flashes a firmware *file*, so you build the ESPHome firmware **first**, then cloudcutter pushes it. After that first flash, every change goes over WiFi (OTA) — you never cloudcutter the same bulb twice.

Recommended order:

① deploy rk1a
② seed the stash secret
③ first bulb
④ remaining bulbs.

______________________________________________________________________

## ① Deploy rk1a

Adds the `esphome` component + opens mDNS (UDP 5353) on rk1a. Already in `homeassistant.nix`.

```sh
cd /path/to/nixos
just deploy rk1a
```

Verify: HA (`https://home.palebluebytes.space`) → Settings → Devices & Services → Add Integration → "ESPHome" should be listed. No device is added yet.

______________________________________________________________________

## ② Seed the ESPHome secrets in stash

On the admin-key machine (where `secrets/` is the stash working copy):

```sh
cd /path/to/nixos/secrets
sops -d profiles/wireless.yaml        # read the fleet WiFi SSID + PSK to reuse
openssl rand -base64 32               # -> api_key_antela_a60_1
openssl rand -hex 16                  # -> ota_password_antela_a60_1
sops profiles/esphome.yaml            # create + edit (sops encrypts on save)
```

Contents (see `esphome/secrets.yaml.example`):

```yaml
wifi_ssid: "<2.4GHz SSID>"
wifi_password: "<PSK from wireless.yaml>"
api_key_antela_a60_1: "<base64 from openssl>"
ota_password_antela_a60_1: "<hex from openssl>"
```

Publish + relock:

```sh
git -C /path/to/nixos/secrets add profiles/esphome.yaml \
  && git -C /path/to/nixos/secrets commit -m "feat(esphome): bulb build secrets" \
  && git -C /path/to/nixos/secrets push
cd /path/to/nixos && nix flake update secrets
```

> The bulbs are **2.4 GHz only** (no 5 GHz radio). A combined SSID is fine; if 2.4/5 are
> split, use the 2.4 GHz one.

______________________________________________________________________

## ③ First bulb, end-to-end

### A. Ground rules

- **Do NOT update the bulb in the Smart Life app.** Note its firmware version, never tap
  update — a patched firmware permanently blocks cloudcutter.
- Needs: a Linux box with an **AP-mode-capable WiFi adapter** (most built-in/ath9k adapters
  work; if the AP won't start, check cloudcutter's compatible-adapter list), **Docker**, and
  the bulb powered nearby.

### B. Build a minimal ESPHome firmware

`esphome/antela-a60.yaml.template` ships with the light section commented out, so it
compiles to a valid wifi+api+ota firmware with no light entity — exactly right for the
first flash (the light is added once the bulb's pins are known).

```sh
cd /path/to/nixos
sops -d secrets/profiles/esphome.yaml > esphome/secrets.yaml   # ephemeral, gitignored
cp esphome/antela-a60.yaml.template esphome/antela-a60-1.yaml   # set name/friendly_name
nix run nixpkgs#esphome -- compile esphome/antela-a60-1.yaml
```

Note the printed `firmware.uf2` path. If `board: cb2l` errors, use
`board: generic-bk7231n-qfn32-tuya` and recompile.

### C. Flash with cloudcutter (this is the go/no-go gate)

```sh
git clone https://github.com/tuya-cloudcutter/tuya-cloudcutter
cd tuya-cloudcutter
cp /path/to/nixos/esphome/.esphome/build/antela-a60-1/.pioenvs/antela-a60-1/firmware.uf2 custom-firmware/
sudo ./tuya-cloudcutter.sh
```

In the menu:

1. Select profile — search "antela"; if absent, pick by chip → **BK7231N**, then the
   profile matching the bulb's firmware (or closest / build-a-profile flow).
1. Choose **flash 3rd-party firmware** → your `firmware.uf2`.
1. Put the bulb in pairing mode when prompted: power-cycle ~3× (on/off/on/off/on) until it
   **blinks fast**.
1. Cloudcutter stands up an AP, the bulb joins, the exploit runs, the UF2 is written.
1. If offered, **save/extract the device config** — the dumped Tuya GPIO schema is needed
   for the light config in step E.

**Go/no-go:** success → bulb reboots into ESPHome, proceed. Failure → firmware is patched;
fall back to `tuya_local` on cloud-cut stock firmware, or a serial flash (revisit ADR-0015).
Record the outcome (chip, profile, dumped config) in `.scratch/antela-bulbs/issues/01`.

### D. Adopt in Home Assistant

The bulb joins WiFi and announces over mDNS. Within ~a minute, HA → Settings → Devices &
Services shows a **discovered ESPHome device**. Configure it, paste the
`api_key_antela_a60_1` value when asked for the encryption key. It appears as a device with
**no light entity yet**.

### E. Add the light (over OTA)

Decode the bulb's PWM pins + driver from the Tuya config saved in step C — paste it into the
[OpenBeken Tuya-config importer](https://openbekeniot.github.io/webapp/templateImporter.html),
which yields the exact GPIO/driver mapping (e.g. 2× PWM CCT, or a BP5758D). If you have no
dump, temporarily flash OpenBeken (auto-detects the mapping), read it, then return to ESPHome.

Fill the matching `output:`/`light:` variant in `antela-a60-1.yaml` (the template lists the
CCT / monochromatic / BP5758D options), then push over the air — no re-flashing:

```sh
nix run nixpkgs#esphome -- run esphome/antela-a60-1.yaml
```

The light entity appears in HA and is controllable. First bulb done.

______________________________________________________________________

## ④ Remaining bulbs + Areas + voice

Per additional bulb: add `api_key_antela_a60_N` / `ota_password_antela_a60_N` to the stash
secret, copy the YAML to `antela-a60-N.yaml` (unique `name`), repeat B–E. Identical hardware
means the light config from bulb 1 carries over — no re-discovery.

Then assign each bulb to an HA **Area** (Settings → Areas, or per-device). Since rk1a is the
voice node, that is all Assist needs — confirm with *"turn on the \<area> light"*.

Automations are phase 2 (declarative in nix per ADR-0015), tracked separately.

______________________________________________________________________

## Quick reference

| Task | Command |
|------|---------|
| Deploy rk1a | `just deploy rk1a` |
| Decrypt build secrets | `sops -d secrets/profiles/esphome.yaml > esphome/secrets.yaml` |
| Compile firmware | `nix run nixpkgs#esphome -- compile esphome/antela-a60-N.yaml` |
| OTA a config change | `nix run nixpkgs#esphome -- run esphome/antela-a60-N.yaml` |
| Check `!secret` refs resolve | `nix run nixpkgs#esphome -- config esphome/antela-a60-N.yaml` |
