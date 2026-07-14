# Runbook: wire Home Assistant's local voice pipeline (rk1a)

Home Assistant's Wyoming STT/TTS integrations and the Assist pipeline are
**config-entry** integrations: HA has no declarative (`configuration.yaml` / NixOS
module) path for them — they are created by config flows and persist in HA's
mutable `/var/lib/hass/.storage`. Rather than seed that private state (which is
version-fragile and silently breaks on HA upgrades), we drive HA's **supported**
config-flow + `assist_pipeline` APIs from a script:

- [`hosts/rk1/ha-provision-voice.py`](../../hosts/rk1/ha-provision-voice.py)

The script is **idempotent** and **fails loud** (non-zero exit, asserts the
pipeline stuck), so it doubles as a post-deploy check. It wires exactly what
[`modules/nixos/profiles/homeassistant.nix`](../../modules/nixos/profiles/homeassistant.nix)
serves: Wyoming STT on `127.0.0.1:10300`, Wyoming TTS on `127.0.0.1:10200`
(`en_US-lessac-medium`), and sets the preferred Assist pipeline's STT/TTS engines.

Because `/var/lib/hass` is persisted, this is a **one-time** action — it survives
reboots, deploys, and everything short of a deliberate state wipe.

## Prerequisites

- HA up on rk1a (`systemctl is-active home-assistant.service`), with the Wyoming
  STT/TTS units running (`wyoming-faster-whisper-en`, `wyoming-piper-en`).
- An HA **owner account**. On a fresh HA the script can create it (onboarding);
  otherwise it logs in.

## Run it (on rk1a, over loopback — no TLS/token needed)

The interpreter only needs the stdlib, so any `python3` works; the example uses
HA's own base interpreter.

```bash
# Fresh HA (no owner yet): create the owner + wire voice in one shot.
HA_OWNER_NAME='Inkpot Monkey' \
HA_OWNER_USERNAME='inkpotmonkey' \
HA_OWNER_PASSWORD='<choose-a-password>' \
  python3 /path/to/ha-provision-voice.py

# Existing HA: log in with the owner creds (no onboarding).
HA_OWNER_USERNAME='inkpotmonkey' HA_OWNER_PASSWORD='<password>' \
  python3 ha-provision-voice.py

# Or with a long-lived access token (Profile -> Security -> Create Token):
HA_TOKEN='<llat>' python3 ha-provision-voice.py
```

Remote (through kelpy) works too: `HA_URL=https://home.<domain> HA_TOKEN=... python3 ha-provision-voice.py`.

A successful run ends with:

```
PASS: Home Assistant voice pipeline is wired for local Wyoming STT/TTS
```

Re-running is safe: it reports `already present` / `already wired` and re-verifies.

## Verify end-to-end

The STT/TTS servers can be exercised directly (piper -> whisper round-trip); see
the scratch `wyoming_e2e.py` recipe used during the rk1a migration (#42), or just
talk to Assist from the HA companion app once the pipeline is wired.

## Optional: run it declaratively as a post-deploy oneshot

To make a from-scratch rk1a come up voice-ready with zero touch, wire the script
as a systemd oneshot after `home-assistant.service`, feeding it a token (or owner
creds) from sops and pointing at loopback. It is idempotent, so running on every
deploy is a no-op once wired, and a failure shows up as a red unit (hook it into
`custom.profiles.monitoring-unit-state` for an alert). Not enabled yet — this
runbook is the manual path.
