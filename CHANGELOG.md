# Changelog

What a flake bump actually changed about the fleet. One entry per bump, newest first,
written by whoever performed it as part of the bump commit (ADR-0038).

**Earlier history is in `git log`.** This file starts on 2026-11-12; the 127 commits that
touched `flake.lock` before it are not reconstructed. `git log --oneline -- flake.lock`
is the record for anything older.

## What belongs here

Only **fleet-visible** change. The test is: *would I want to know this when something
behaves oddly next month?* A service that moved a major version, a package that started
or stopped being substitutable, a hold opened or released, a setting that had to change
to survive the bump — those go in. Refactors, new checks, docs and anything invisible
from a running host are left to `git log`.

Holds are not described here in full. They live in [`docs/holds.md`](docs/holds.md), one
anchor each; an entry below links the anchors it opened or closed and says nothing more.
See [`docs/runbooks/flake-bump.md`](docs/runbooks/flake-bump.md) for the procedure that
produces both.

## The shape of an entry

```markdown
## 2026-11-12

**Moved.** nixpkgs 2026-11-07 → 2026-11-10. tuwunel 1.9.3 → 1.9.4.

**Broke.** `matrix-hookshot` stopped building on unstable (`libsqlite3-sys`).

**Held.** [matrix-hookshot](docs/holds.md#matrix-hookshot) — taken from `nixpkgs-stable`.

**Released.** [snapcast](docs/holds.md#snapcast) — 0.35.0 verified against Music
Assistant on porcupineFish, pin dropped.
```

Omit any heading that has nothing under it. A bump where nothing broke, nothing was held
and nothing was released is one **Moved** line, and that is a good entry.

<!-- Entries begin below. Newest first. -->
