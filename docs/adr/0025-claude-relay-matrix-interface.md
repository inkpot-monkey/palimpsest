---
status: accepted
---

# Claude relay: Matrix is the primary interface to persistent `claude` sessions

AionUi (ADR-0005/0008) gave a phone-accessible Claude frontend plus one-way Matrix
alerts, but its WebUI is clunky and its Matrix side is read-only. We replace it with a
**Claude relay**: a bespoke service on `kelpy` that runs persistent `claude` CLI sessions
in `tmux` and exposes them *through Matrix* as the primary, two-way interface — Matrix
messages are injected into the session and each turn is posted back. A direct
**ghostel** terminal attach (`ssh -t kelpy tmux attach`) is the escape hatch for the raw
TUI. This deliberately reopens the two-way-Matrix question ADR-0008 deferred.

The relay is a single long-running daemon (Rust + `matrix-rust-sdk`, a **bot account**,
in-repo service module `modules/nixos/services/claude-relay/`) running as `inkpotmonkey`.
It owns the `/sync` loop, a `127.0.0.1` endpoint that the `claude` CLI hooks POST to, the
`tmux` sessions, and a persisted `session_id ↔ tmux ↔ room_id` map. Topology is a single
**control room** (`new <cwd>` / `list` / `kill`) plus one **session room** per session.
Output is **transcript-driven**: the `Stop` hook posts the assistant turn + one-line tool
summaries (read from `~/.claude/projects/.../<id>.jsonl`); the `Notification`
(`permission_prompt`) hook posts an **MSC3381 poll** whose response the relay maps to a
`tmux send-keys` — so permission grants and Claude's own multiple-choice prompts are one
path. Sessions are **ephemeral but resumable on demand**: a reboot ends the `tmux`
processes, and the relay offers a one-tap `claude --resume <id>` (the transcripts persist).

## Security model (the load-bearing part)

Unlike AionUi — whose only boundary was the Tailscale range (ADR-0005) — the relay rides
the homeserver, which is **public and federated** (`allow_federation = true`, fronted as a
public Caddy service for federation to work). So the network-isolation boundary does *not*
apply. The control plane injects free text into a `claude` agent that executes arbitrary
code as `inkpotmonkey` on the **exposed** VPS, so the blast radius is identical to
ADR-0005's: full code-exec as that user. The boundary is therefore:

- The bot executes input **only from a single hard-allowlisted sender MXID**, enforced
  **in the bot itself** (not via room ACLs — a federated room's power-levels don't fully
  gate spoofing/joins).
- **Matrix account credentials are now equivalent in power to host root on kelpy.** Account
  compromise = full code-exec as `inkpotmonkey`. This is accepted, the same blunt stance
  ADR-0005 takes for the Tailscale range.
- Rooms are created **non-federated** (`m.federate = false`) with local-homeserver members
  only, so the prompt/code stream never leaves kelpy over federation. This *replaces* E2E:
  with the homeserver co-located with the relay and agent, E2E's only real protection
  (homeserver compromise / federation leakage) collapses to "the box is already owned," so
  E2E is **dropped** to remove the bot's fiddliest part.

## Considered Options

- **A headless emacs daemon on kelpy running `claude-code.el`** (the original framing) —
  rejected. The emacs/`ai` home profiles are gui-only (`profiles.nix`, gated on
  `hostFacts.granted.gui`), and kelpy can't take `gui` (an *incapacity* per CONTEXT.md, not
  a policy). It would mean decoupling emacs from `gui`, a custom Lucid build for remote
  frames, and ghostel-in-TUI nesting — all to add **nothing** to persistence (a multiplexer
  does that), notifications (CLI hooks do that), or inject-back (`send-keys` does that).
- **A Matrix appservice** (consistent with ADR-0006) — rejected for the relay. It needs
  none of an appservice's powers (ghost namespaces, masquerade, invite-less event receipt);
  it has one identity reading one allowlisted user. A bot + `matrix-rust-sdk` is far less
  code (`/sync` + handlers vs a hand-rolled transaction receiver), iterates without a
  homeserver restart, and isn't even more secrets. Cost: it's the lone self-registered
  account, with one `access_token` in stash.
- **Python + matrix-nio** vs **Rust + matrix-rust-sdk** — chose Rust. It consolidates all
  first-party Matrix services on one stack/toolchain alongside the jmap bridge (ADR-0017),
  rather than keeping the notifier's Python alive.
- **Keep AionUi / extend its notifier two-way** — rejected. aioncore can't push and its
  native-channel route is a Rust fork (ADR-0008); the WebUI is the thing being replaced.

## Consequences

- **Supersedes [ADR-0005](0005-aionui-tailscale-only-boundary.md) and
  [ADR-0008](0008-aionui-matrix-via-rest-poller.md)**; AionUi (WebUI + notifier) is removed
  **atomically when the relay lands** (no notification gap), keeping the WebUI only as a
  fallback during bring-up. [ADR-0024](0024-matrix-hookshot-webhooks-and-feeds.md)'s
  hookshot **stays** for GitHub/feeds/generic webhooks — only its aionui generic-webhook
  connection (the `aionui-hookshot-provision` oneshot + `#aionui-alerts` room) goes.
- **One new stash secret** — the bot's long-lived `access_token` (account created once via
  the existing `registration_token`).
- **The relay provisions Claude's hooks**, writing `~/.claude/settings.json` with the
  `Stop`/`Notification` hooks → a script that `curl`s the relay endpoint, because the home
  `ai` profile that would normally own claude config is gui-only and absent on kelpy.
- **Concurrency is capped (default 2)** to bound subscription-quota burn, kelpy's
  resources, and the blast radius of N code-exec agents.
- **`tmux` is the substrate** (not a relay-owned PTY) *specifically because* the ghostel
  attach needs a shared multiplexer; the relay only `send-keys` (input) and reads the
  transcript on hooks (output).
- **Selectable choices are Element-centric** (MSC3381 polls render as cards in Element;
  other clients see fallback text) — acceptable since Element is the operator's client.
- **The relay may graduate to its own repo** later the way the jmap bridge did (ADR-0017);
  today it is kelpy-specific glue.
