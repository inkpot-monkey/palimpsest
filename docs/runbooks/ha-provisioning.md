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
fresh.

> ⚠ **This is no longer "nothing of value is lost".** It was true while HA had been
> running for days with nothing in it. The provisioner reproduces the config entries,
> the areas and the pipeline — but not the recorder's history (state history and the
> long-term statistics the energy dashboard draws on, which nothing regenerates), nor
> anything renamed or built in the UI, nor the Companion app's tokens. Take a dump
> first (`systemctl start ha-db-dump`, then copy `/var/lib/hass/db_*.sqlite3` somewhere
> off the host) and expect to re-pair the phone. See the "Backups and logs" section.

```bash
ssh rk1a 'sudo systemctl stop home-assistant home-assistant-provision \
  && sudo find /var/lib/hass -mindepth 1 -delete'
# deploy rk1a; on start the oneshot onboards `admin` and re-wires the pipeline.
ssh rk1a 'systemctl is-active home-assistant-provision'   # -> active (exited)
```

After a *deliberate* state wipe later, re-run with
`systemctl start home-assistant-provision`.

## Backups and logs

Both are declarative and need nothing from this runbook in normal operation; this
section is the map for when something looks wrong.

**Logs** go nowhere special: Home Assistant writes to stdout, systemd puts that in
the journal, and Vector ships it to VictoriaLogs like every other unit on the fleet
(ADR-0021). Two deliberate consequences:

- HA's own `home-assistant.log` is **off** (`HA_DISABLE_LOG_FILE`), because it is a
  second copy inside the directory this host backs up. So Settings → System → Logs
  has no "Load full logs" download — use `journalctl -u home-assistant` or the Logs
  dashboard. Flip `custom.profiles.homeassistant.logging.fileLog = true` to get it
  back.
- HA's severity is parsed out of its **message text**, not journald's `PRIORITY`.
  Everything it writes to stdout is PRIORITY=6, so without that its errors would
  arrive labelled `info` and the Logs dashboard's Errors/Warnings panels — which
  select on `level` — would show zero no matter how loudly it was failing. The
  pattern lives in `custom.profiles.monitoring-client.levelFromMessage`; a traceback's
  continuation lines deliberately stay `info` (one error, not twenty).

Check it end to end from rk1b:

```bash
ssh rk1b 'curl -s http://localhost:9428/select/logsql/query \
  --data-urlencode "query=host:rk1a AND unit:home-assistant.service AND level:in(error,warning) | stats count() n" \
  --data-urlencode "start=24h"'
```

**Backups** are rk1a's `daily` restic job (`hosts/rk1/ha-backup.nix`): `.storage`,
`blueprints` and the recorder **dump**, plus `/var/lib/nixos` so a restore lands on
the right `hass` uid. The live `home-assistant_v2.db` triple is excluded — copying an
open WAL database is not a restorable artifact — and
`ha-db-dump.service`/`.timer` writes `db_<UTC>.sqlite3` beside it at 02:45 and 14:45,
fifteen minutes before each restic run.

```bash
ssh rk1a 'systemctl status ha-db-dump.timer --no-pager | head -5
           sudo ls -la /var/lib/hass/db_*.sqlite3
           journalctl -u ha-db-dump -n 3 --no-pager'
ssh rk1a 'systemctl list-timers restic-backups-daily-rsyncnet --no-pager'
```

If the dumps stop, `ha-dump-freshness` **refuses the whole job** rather than ship a
snapshot with stale history (20h limit, so one missed dump is tolerated and two are
not). That shows up as the job going cold on the Backups board, not as an alert —
rk1a holds no matrix credential. The restore procedure, and why it is a dump rather
than HA's own backup integration, are in the header of
`modules/nixos/profiles/ha-db-dump.nix`.
