# Agent jobs: hermes on rk1b

Scheduled work the hermes gateway owns, which may invoke a model. The vocabulary is in
`GLOSSARY.md` (**Agent job**, **Source script**); the decisions behind this file are
[ADR-0041](../adr/0041-an-agent-job-is-state-and-the-fleet-declares-its-boundaries.md).

The CLI is the authority on flags — `hermes cron create --help`, run as the service user:

```sh
sudo -u hermes -H env HERMES_HOME=/var/lib/hermes/.hermes hermes cron <subcommand>
```

## Pick the mode from what the model is for

Three modes, and the choice is the whole design of a job:

| Mode | The model | Reach for it when |
| --- | --- | --- |
| `--no-agent --script X` | never runs | the answer is deterministic. Empty stdout is silent — the classic watchdog |
| `--monitor-script X` | runs only on change | detection is deterministic and the **judgement** is not |
| prompt only | runs every tick | the value is judgement every time, which is rare |

`--monitor-script` is the default shape. It hashes the script's exact bytes: unchanged output
suppresses the model entirely, changed output arrives in the prompt as `MONITOR CHANGE DETECTED`. A quiet day costs approximately zero tokens. Script output must be stable — a
timestamp in it defeats the hash and the model runs every tick.

This is ADR-0038's boundary made real: **the model judges what moved and never detects.**

Split a job rather than widening one. Bookkeeping that needs no model (fetching, diffing,
recording) belongs in a `--no-agent` job or the watcher tier; the agent job runs over what
changed.

## Channels

Two kinds, and they travel different paths on purpose:

- **Per-job channel** — a Matrix room the job delivers into, through hermes's own `matrix`
  platform, so the job can be *answered* rather than only read.
  `--deliver matrix:<room id>`.
- **General hermes alerts** — the Infra Alerts room, so a failure lands where every other fleet
  alert does. `--failure-deliver matrix:<infra-alerts room id>`.

Routine output stays out of Infra Alerts: that room is kept scannable and muteable, and a daily
"nothing moved" erodes it.

### The delivery grammar, which is easy to get wrong

`--deliver` takes `platform:chat_id`, split on the **first** colon — so
`matrix:!abc:matrix.palebluebytes.space` reads as platform `matrix`, room
`!abc:matrix.palebluebytes.space`. Three traps:

- **`--deliver room:<id>` is NOT a Matrix room.** `room:` is a hermes-internal *Bot Mode Group
  Chat*, appended to the gateway's own room store in `state.db`
  (`cron/scheduler_delivery_room.py`). It delivers nowhere a person can see.
- **A room ALIAS does not work.** The adapter hands the chat id straight to
  `send_message_event(RoomID(chat_id))` — `PUT /rooms/{id}/send/…` — and resolves no alias
  anywhere in the plugin. It must be the `!…` id.
- **Bare `--deliver matrix`** means `MATRIX_HOME_ROOM`, which this fleet deliberately leaves
  unset (`modules/nixos/profiles/hermes.nix`): every job names its room, so nothing can fall
  back into a room it was not pointed at.

**Where the room ids are.** Rooms are declared on kelpy
(`custom.profiles.matrix.hermesRooms.rooms.<job>`) and created by
`matrix-hermes-rooms.service`, which persists each id:

```sh
ssh kelpy cat /var/lib/matrix-hermes-rooms/<job>.room-id   # the per-job room
ssh kelpy cat /var/lib/matrix-infra-alerts/room-id         # Infra Alerts
```

Ids are minted by the homeserver and die with a `matrix-reset`, so they are not in the repo and
are not sops values — pointing a job at one is a `hermes cron update`, like every other thing
about a job.

## Where things live

| | |
| --- | --- |
| Jobs | `jobs.json` under `$HERMES_HOME` — state, created by hand, backed up |
| Source scripts | `$HERMES_HOME/scripts/` |
| Operator skills | a store path, via `skills.external_dirs` |
| Agent's own skills | `$HERMES_HOME/skills/` — the learning loop, left alone |
| Per-job durable state | `hermes cron notepad` |
| The index of what exists | `docs/agent-jobs.md` |

A source script is **mutable by default**, so the agent can improve it. Declare it through
`hermesHomeFiles` only when its job writes outside the agent's own state or acts on the fleet —
declaring freezes it, because activation overwrites.

## Handover checklist

A job is ready to hand to hermes when every line is evidenced:

1. An issue exists on `inkpot-monkey/palimpsest` carrying the job's reasoning.
1. Its per-job Matrix room exists, and `--failure-deliver` points at Infra Alerts.
1. A source script exists, and its declared-or-mutable status is a stated choice, not a default.
1. An entry is in `docs/agent-jobs.md` naming the job, its issue, its channel and that status.
1. The overdue-job check knows about it, so its silence is noticed.
1. `hermes cron create …` has been run **by a human**, and `cron.preflight` passed — it verifies
   the provider key resolves, attached skills are ready and delivery is configured, failing to
   `last_status=blocked_config` with one alert and no model call.

## Gotchas

- **`AGENTS.md` is read from the cwd.** A job started anywhere other than its `--workdir` sees
  no project context. `--workdir` injects it and sets the cwd for terminal and file tools.
- **`cron.allow_agent_scheduling` is `false`.** A cron run cannot create or edit jobs. Improving
  a job's prompt happens in an interactive session, with a human present.
- **The unit PATH is not the login PATH.** It excludes `/run/current-system/sw/bin`, so a tool
  installed fleet-wide is invisible to the agent. What the agent may run is named in the
  profile's `extraPackages`.
- **Declaring into `$HERMES_HOME/skills/` collides with the agent writing there**, and
  activation wins. Operator skills go in `skills.external_dirs`.
- **`schedule` is positional**, not `--schedule=` — the flag spelling errors with
  "unrecognized arguments".
- **A `.py` source script does not run on NixOS.** hermes dispatches it to a "dependency
  environment" interpreter inside its own package (`.../site-packages/venv/bin/python`),
  which does not exist here — the run fails with `dependency environment interpreter is missing` before the script is reached. Ship a `.sh` wrapper that `exec`s
  `${pkgs.python3}/bin/python3` on the `.py`; carrying the interpreter from the flake
  beats `--interpreter` with a store path, which goes stale on the next hermes upgrade.
- **The service is sandboxed; `sudo -u hermes` is not.** hermes-agent runs
  `ProtectSystem=strict` with `ReadWritePaths=/var/lib/hermes`, so a job writing anywhere
  else fails however the file modes read — and the failure does NOT reproduce when you
  test the script by hand as the hermes user. Grant the specific directory via
  `systemd.services.hermes-agent.serviceConfig.ReadWritePaths`.
- **Adding hermes to a group needs a unit restart.** Supplementary groups are fixed at
  process start, and `nixos-rebuild switch` does not restart a unit whose own definition
  is unchanged. The deploy goes green and the service still cannot reach the tree.
- **The first monitor run wakes the model anyway.** With no previous output to diff
  against, hermes reports `Monitor Baseline (first run)` and invokes the model — even when
  the script printed nothing. A bootstrap done by hand outside the monitor does not
  prevent this; it just means the model's first run sees an empty delta.
- **A source script is found only under `$HERMES_HOME/scripts/`.** `--script` takes a path
  there; a script elsewhere is not found. `.py` runs under Python, `.sh`/`.bash` under bash.
- **A cron run pins the hermes tree on `PYTHONPATH`, not your workspace packages.** A wrapper
  importing a package from the workspace needs `sys.path.insert(0, …)` at the top. *(Reported by
  the agent-authored `scheduled-data-collection` skill; confirm on the first job that needs it.)*
