# Emacs config — domain glossary

The `inkpotmonkey` Emacs configuration: a `use-package` `init.el` plus a set of
**local modules** (bespoke elisp packaged from this tree). This glossary fixes
the language used across the config so commit messages, module commentary, and
future architecture reviews stay consistent. It is scoped to this directory; the
repo-root [`CONTEXT.md`](../../../../CONTEXT.md) is the *fleet* glossary and does
not reach here.

## Language

### Modules & packaging

**Local module**:
A bespoke elisp package built from a subdirectory of this tree (`agents-hud/`,
`proc-notify/`, `claude-session/`, …) via `melpaBuild` in `packages.nix`, rather
than fetched from MELPA/nixpkgs. The convention is *every non-trivial feature is
a module, not inline `init.el` code*: `init.el` holds only `use-package` wiring;
the module owns the logic and (where it has pure logic) an ERT suite run at build
time through the package's `checkPhase`. Deep implementations are lifted out of
`init.el` into named modules for exactly this reason.
_Avoid_: script, snippet (for a module); component.

**The Nix seam**:
The prod/dev adapter split for host- and user-specific facts. Nix generates
`my-site-config.el` (username, email, secrets path, tree-sitter grammars); the
`defvar` fallbacks in `init.el` keep the file loadable and byte-compilable
outside Nix. The generated module is the prod adapter; the fallbacks are the dev
adapter — two adapters, so the seam is real rather than hypothetical.
_Avoid_: template, `@token@` substitution (deliberately not used).

### Terminals, sessions & agents

> Both Claude Code sessions and plain terminals run on **ghostel** (a libghostty
> PTY terminal); claude-code drives the ghostel backend, so a `*claude:…*` buffer
> and a `*ghostel:…*` buffer are both `ghostel-mode` buffers. Several modules care
> about "what is running and what is it doing", so the vocabulary below fixes who
> owns which part.

**Claude session** (or just **session**):
A live `*claude:DIR:name*` claude-code buffer (or a plain `*ghostel: TITLE*`
terminal) and its live status. Ephemeral — it dies with the buffer. Owned by the
**`claude-session`** module, the single owner of session *discovery* (the
`*claude:` predicate), the `*claude:DIR:name*` *name parse*, and the *status
model*. Every other view reads it (`claude-session-at` / `-list` / `-status`)
rather than re-deriving it.
_Avoid_: agent (reserve for a project-agent workspace/run), instance (that is the
per-session `name` suffix, not the whole session), process/buffer (too low-level —
a session is a buffer *plus* its resolved status).

**Status model** (the four states):
A session's live state, resolved by priority `dead → waiting → working → ready`:
**working** (the terminal is churning — ghostel's OSC-133 `command-running` flag,
or a recent redraw), **waiting** (Claude is BLOCKED on a selection prompt and
needs a choice — detected by *screen-scanning* the live buffer, **not** the
end-of-turn bell, which fires every turn), **ready** (live, quiet, standing by),
**dead** (no live process). Owned by `claude-session`; the canonical vocabulary
all consumers speak.
_Avoid_: running/finished as the *model* (that is project-agent's coarser
two-value **run status**, derived from this: `dead` → finished, else running);
busy/idle.

**Background shells** (the `shells` count):
How many `run_in_background` shells a Claude session has running, a signal
**orthogonal to the state** (a session can be `ready` yet have a shell running).
Read by `claude-session` from the live screen — Claude's TUI reports it in the
input footer (`· N shell ·`) and the worked line (`N shell(s) still running`),
which `claude-session--shell-count` matches while excluding the past-tense
`Ran N shell command` in scrollback. The HUD renders it as a mono-glyph **shell
badge** (`$N`) in a row's trailing status column, in the same family as the
state icons.
_Avoid_: folding it into a state (it is a count, not a state — a session's state
and its shell count vary independently).

**Signal collection** (the ghostel adapter):
The ghostel-coupled side of the status model: the buffer-local redraw/focus/
keystroke/exit stamps and the interaction-repaint guards (which discount a redraw
*you* caused — a focus repaint or keystroke echo — so looking at a parked session
does not flash it as working). Installed by `claude-session-setup`. It is the
adapter to ghostel's internals, deliberately concentrated in one module so the
version coupling is owned in one place.
_Avoid_: hooks, listeners.

**The HUD**:
`agents-hud` — the live status *view* over sessions, rendered two ways from one
backend: a toggleable right-side sidebar (`C-x C-a`, grouped by project,
attention floats to the top) and an "Agents" `consult-buffer` group. Post-split
it owns only the *rendering* side — sort, grouping, sidebar/consult decoration,
and the git worktree/branch labels — building an `agents-hud-entry` (a
`claude-session` plus that git decoration).
_Avoid_: dashboard, panel (for the module as a whole; "sidebar" for the window is
fine).

**Run** (project-agent run):
A **durable** agent-workspace record under a project's `.agent/runs/` — a UUID
(`project-agent--run-id`, stamped on the session buffer), a prompt, and a
manifest with a `running`/`finished` status. Distinct from a **Claude session**:
a run *outlives* its buffer (it persists after the terminal is gone), and a run
may have a live session or none. `project-agent` owns runs; it asks
`claude-session` whether a run's buffer is live and what its status is, never the
reverse.
_Avoid_: session (a run is durable, a session is live), job.

**Backend** (project-agent):
The `cl-defgeneric` protocol (`project-agent-launch` / `-resume` /
`-list-sessions` / `-session-status`) that keeps `project-agent`'s core
agent-agnostic; the claude-code implementation lives in
`project-agent-claude-code.el`. Genuinely abstract (it might gain another agent),
unlike `claude-session`, which is deliberately concrete to claude-code/ghostel.
_Avoid_: driver, provider.

**Claude TUI glue** (`claude-tui`):
The module that makes claude-code's full-screen ghostel TUI behave in this
config, concentrating the two things a ghostel bump would break. (1) The
**snippet expander**: because ghostel forwards keystrokes straight to Claude's
alt-screen TUI (the text lives in the terminal grid, out of reach of
abbrev/tempel/corfu), TAB is overridden to read the word left of the cursor off
the grid and, if it is a **trigger** in `claude-tui-snippets` (a
`(trigger . expansion)` alist), replace it — the grid→trigger step is the pure,
tested `claude-tui--trigger-at`. (2) The **copy-mode shim**: a compatibility
bridge for claude-code.el expecting ghostel's pre-0.31 `ghostel--copy-mode-active`
API. `claude-tui-setup` wires both.
_Avoid_: abbrev (the store is a plain alist, not an abbrev table — the trigger
lookup only ever *read* the old table, never expanded it); keybinding (the
expander is grid manipulation, not an Emacs-buffer edit).

### Attention & notification

**Attention set** (proc-notify's awaiting-buffers):
The buffers `proc-notify` lists on the pull side (`C-c n`, and the `!`
`consult-buffer` source) as *wanting input*: pending desktop-notification pings
∪ comint processes parked at a prompt ∪ **Claude sessions in the `waiting`
state**. The last term is read from `claude-session`, so a session blocked
mid-turn on a permission/plan prompt — which the once-per-turn claude-code bell
misses — is surfaced here too. `proc-notify` is a *superset* consumer: it also
covers non-Claude comint buffers, so it reads the session status as one input
rather than being replaced by it.
_Avoid_: notification list (that is the push side — the desktop toasts).

**Ping** (vs **waiting**):
Two different attention events, kept distinct. A **ping** is a transient event —
claude-code's end-of-turn bell, a password prompt — that `proc-notify` toasts
once. **waiting** is a *state* — Claude blocked on an on-screen selection prompt —
that `claude-session` screen-detects and both the HUD and the attention set
surface for as long as it holds. A ping is not a state; a state is not an event.
_Avoid_: conflating the bell (event) with the selection prompt (state).

## Non-goals

Refactors considered and deliberately **not** done, recorded so a future
architecture pass does not re-suggest them.

**Unifying the "three process-exit sentinels".** At a glance `proc-notify`,
`whisperx`, and `chelys-galactica` look like three copies of one sentinel shape
("on exit, check status, act"). They are not: `proc-notify` advises the _single
shared_ `shell-command-sentinel` chokepoint (already good composition, not its
own sentinel); `whisperx--sentinel` is a domain **process supervisor** for a
serial job queue (revert the dired buffer, open the result, chain the next job),
which must not be folded into a notifier; and `chelys-galactica` has no sentinel
at all (it delegates to recall + Emacs). A shared "buffer → command" naming
helper — the one genuinely duplicated bit (`proc-notify--summary`'s
`async-shell-history--command` probe vs `chelys-galactica--command`'s
rename-persistence tag) — would be a ~3-line `or` that **fails the deletion
test** (relocating, not concentrating, complexity) and whose two callers want
different things. The serial-job-queue in `whisperx` has exactly one user, so
extracting it is speculative generality (one adapter is a hypothetical seam, not
a real one). Left as-is.
