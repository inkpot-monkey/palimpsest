# Runbook: provision Home Assistant's non-declarable state (rk1a)

Parts of Home Assistant have no declarative (`configuration.yaml` / NixOS module)
path at all: config-entry integrations are created by config flows, the Assist
pipeline is edited through the UI, and since 2026.9 the `http` settings live in
HA's own store, which *ignores* the YAML block once migrated. All of it persists
in mutable `/var/lib/hass/.storage`. Rather than seed that private state (which is
version-fragile and silently breaks on HA upgrades), we drive HA's **supported**
APIs from a script:

- [`hosts/rk1/ha-provision.py`](../../hosts/rk1/ha-provision.py)

The script is **idempotent** and **fails loud** (non-zero exit, asserts each change
stuck), so it doubles as a post-deploy check. Idempotency is not a nicety here: a
spurious HTTP change restarts Home Assistant, so a sloppy comparison would restart
it on every boot. It provisions exactly what
[`modules/nixos/profiles/homeassistant.nix`](../../modules/nixos/profiles/homeassistant.nix)
declares:

- **HTTP** — `server_port`, `use_x_forwarded_for` and the edge host's
  `trusted_proxies`. Without this the module's declared proxies would silently stop
  taking effect and the reverse proxy would break on the next address change.
- **Voice** — Wyoming STT on `127.0.0.1:10300`, TTS on `127.0.0.1:10200`
  (`en_US-lessac-medium`), and the preferred Assist pipeline's STT/TTS engines.
- **Bulbs** — each `provision.bulbs` entry adopted through `tuya_local` and placed
  in its Area, which is what lets Assist address it by room (ADR-0037).

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
  python3 /path/to/ha-provision.py

# Existing HA: log in with the owner creds (no onboarding).
HA_OWNER_USERNAME='inkpotmonkey' HA_OWNER_PASSWORD='<password>' \
  python3 ha-provision.py

# Or with a long-lived access token (Profile -> Security -> Create Token):
HA_TOKEN='<llat>' python3 ha-provision.py
```

Remote (through kelpy) works too: `HA_URL=https://home.<domain> HA_TOKEN=... python3 ha-provision.py`.

A successful run ends with:

```
PASS: Home Assistant HTTP config, local voice pipeline and bulbs provisioned
```

Re-running is safe: it reports `already present` / `already wired` and re-verifies.

## Verify end-to-end

The STT/TTS servers can be exercised directly (piper -> whisper round-trip); see
the scratch `wyoming_e2e.py` recipe used during the rk1a migration (#42), or just
talk to Assist from the HA companion app once the pipeline is wired.

## Declarative path (default on rk1a): the post-start oneshot

`custom.profiles.homeassistant.provision.enable = true` (set on rk1a) installs
`home-assistant-provision.service` — a oneshot that runs after HA + the
Wyoming servers, waits for HA's API, then runs this script against loopback. It
is idempotent, so it is a no-op once wired; a failure surfaces as a red unit
(hook it into `custom.profiles.monitoring-unit-state` for an alert). The owner
account (`admin` by default, `provision.ownerUsername`) is created on the first
run from a sops secret.

### The secret

The service needs `ha_owner_password`, plus one `local_key_<slug>` per declared
bulb. They all live in the same sops file in the secrets repo:
`secrets/profiles/homeassistant.yaml`, keyed to `admin` + `rk1a` (the creation rule
is already in `secrets/.sops.yaml`). One file, because sops grants per file and
that pair is exactly right for every key in it — see ADR-0037.

Bulb keys are loaded as systemd credentials, not environment variables, and the
script reads each from `$CREDENTIALS_DIRECTORY` itself.

```bash
# In the secrets repo working copy (where the admin age key lives):
sops secrets/profiles/homeassistant.yaml     # add:  ha_owner_password: <password>
git -C secrets add profiles/homeassistant.yaml .sops.yaml
git -C secrets commit -m "feat(ha): owner password for voice provisioning"
git -C secrets push
# Back in the nixos repo, pull the new secret into the flake input, then deploy:
nix flake update secrets
```

Because the owner username is changing from the migration-era `inkpotmonkey` to
`admin`, the account must be re-created: wipe HA's state so the oneshot onboards
fresh (state is otherwise reproduced by this script, so nothing of value is lost):

```bash
ssh rk1a 'sudo systemctl stop home-assistant home-assistant-provision \
  && sudo find /var/lib/hass -mindepth 1 -delete'
# deploy rk1a; on start the oneshot onboards `admin` and re-wires the pipeline.
ssh rk1a 'systemctl is-active home-assistant-provision'   # -> active (exited)
```

After a *deliberate* state wipe later, re-run with
`systemctl start home-assistant-provision`.
