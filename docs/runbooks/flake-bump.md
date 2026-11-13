# Runbook: bumping the flake

How to move `flake.lock` forward, deploy the result, and — the part that keeps getting
lost — **write down anything you had to hold back, at the moment you hold it back**.

A bump happens every two or three days and is usually uneventful. The uneventful path is
the first section; everything after it is for the bump that fights you.

Design: [ADR-0038](../adr/0038-held-back-packages-are-a-registry-an-agent-rechecks.md).
The registry is [`docs/holds.md`](../holds.md).

## The whole loop

```console
$ cd ~/code/nixos
$ NIX_CONFIG="access-tokens = github.com=$(gh auth token)" nix flake update
$ nix flake check -L
$ just build                       # the local workstation first
$ just deploy kelpy                # then each remote host, one at a time
```

Then, in **one commit**: the lock, a `CHANGELOG.md` entry, and — if anything had to be
held — the pin, its `# HOLD:` comment, and the `docs/holds.md` entry.

## 1. Update the lock

```console
$ NIX_CONFIG="access-tokens = github.com=$(gh auth token)" nix flake update
```

Unauthenticated it gets `429: Too Many Requests`. The token goes through the
**environment**, never `--option` — `AGENTS.md` → *Operational gotchas* has the reason and
the standing fix.

### A blanket update is not always what you want

Several inputs are pinned on purpose and a blanket `nix flake update` either skips them
silently or moves something far larger than you intended. `flake.nix` carries every pin's
reasoning; this table carries only what it changes about *this* procedure:

| Input | On a routine bump |
| --- | --- |
| `nixpkgs` | The point of the exercise. Moves the fleet. |
| `nixpkgs-stable` | A release *branch*, so it picks up backports on its own. Leave it. |
| `nixpkgs-frozen` | A frozen rev holding `stump`'s closure. Never moves on a bump. |
| `jmap-bridge` | Pinned to a release **tag**, so `nix flake update jmap-bridge` is a **no-op**. See below. |
| `nixos-raspberrypi` | Moves porcupineFish's kernel **and its whole userspace**. Never on a routine bump. See below. |
| `supernote` | A bare `?rev=`, deliberately. Moving it can migrate the live device-sync database. Edit the rev by hand, with a `sqlite3 .backup` first. |
| `users`, `secrets`, `contract` | Separate repos. Push there first, then `nix flake update <input>` here. `just switch` already refreshes `users`. |
| `hermes-agent`, `claude-cowork-linux` | Carry their own nixpkgs on purpose. They move, but nothing of ours follows them. |

To move just one thing:

```console
$ NIX_CONFIG="access-tokens = github.com=$(gh auth token)" nix flake update nixpkgs
```

### `nixos-raspberrypi` is not a routine bump

Don't move it as part of one. It is its own operation, gated on a `stable_*` kernel tag
and on having the device in front of you — the rules are in `AGENTS.md` → *Operational
gotchas* and [`hosts/porcupineFish/README.md`](../../hosts/porcupineFish/README.md), and
they must be read before the rev changes, not after.

### `jmap-bridge` has to be bumped by hand, and proven warm

Edit the tag in `flake.nix` (`gh release list --repo palebluebytes/jmap-matrix-bridge`);
`nix flake update jmap-bridge` on a tag pin is a silent no-op — see `AGENTS.md`.

The part that lives nowhere else is the **warmth check**. A tag proves CI built that
closure once; it does not keep it alive, and cachix retention here is weeks. Before
deploying, ask the cache — not the local store, because a local dry-run prints nothing at
all once the path is already here, which reads like success:

```console
$ h=$(basename $(nix eval --raw \
    "github:palebluebytes/jmap-matrix-bridge/<tag>#packages.x86_64-linux.default.outPath") \
    | cut -d- -f1)
$ curl -s -o /dev/null -w '%{http_code}\n' "https://palebluebytes.cachix.org/$h.narinfo"
200
```

`404` means kelpy will compile `matrix-sdk`/`sqlx` from source — half an hour, no error,
just silence.

## 2. Check and build

```console
$ nix flake check -L
```

Locally, not in CI: CI runs against the mock secret set and cannot catch a
secret-dependent regression (`AGENTS.md`). `git add` any new file first, or it fails at
*eval*, not as a missing file.

Build before you deploy anything:

```console
$ just build                 # this host
$ just build kelpy           # any named host, locally
```

A build failure here is cheaper than one mid-deploy, and it is where a `*-sys` link error
or a missing `buildInputs` will surface.

## 3. Deploy

One host at a time, starting with the one you are sitting at.

```console
$ just switch                      # local workstation
$ just deploy kelpy
$ just deploy rk1b                 # before rk1a — rk1b is the aarch64 builder
$ just deploy rk1a
$ just deploy potbelliedSeahorse
```

That order is the whole of the step: rk1b before rk1a because rk1b is the fleet's aarch64
builder, and nothing before the host you are sitting at. `just deploy` handles the rest
itself, including kelpy's sudo password (`AGENTS.md`).

porcupineFish is deliberately absent from the list. Deploy it only when you have the
device in front of you, and only after reading the kernel note above.

## 4. When something will not build — record the hold now

This is the step the whole runbook exists for. You have just been interrupted, the fix is
"pin it and move on", and the knowledge of *why* is at its most complete and its most
perishable. Record it in the same motion as the pin, before you deploy, before you
context-switch.

**Three things, together:**

### a. Make the pin

Whatever the escape is — `nixpkgs-stable` for a package that exists there,
`nixpkgs-frozen` for one of ours, a version override in
`modules/shared/overlays/default.nix`. Prefer the stable *release branch* over a frozen
rev: a branch keeps receiving backported security fixes, a frozen rev rots.

### b. Point the pin at the registry

One line, and put it where a reader *lands* — directly above the attribute they will have
grepped for, not at the head of a comment block several lines up:

```nix
# HOLD: docs/holds.md#matrix-hookshot
```

For a **new** pin that is the whole Nix-side comment. Write the reasoning in `holds.md`
once; the pin gets a signpost, not a second copy.

The pins backfilled into the registry kept their original prose as well, and that was
deliberate: it is the better read in place, and ADR-0038 rejected *scraping* those
comments precisely so they could stay prose. Trimming them back to a bare pointer is a
separate decision nobody has made. So: don't add new prose beside a new pointer, and
don't delete the prose that is already there as a side effect of something else.

### c. Write the entry in `docs/holds.md`

Follow the shape already in that file. The fields that earn their keep:

- **The exact failure.** The crate, the linker error, the build-script message — the
  string you would grep for in six weeks.
- **A machine-runnable probe**, from the closed vocabulary at the head of `holds.md`.
  Usually `nixpkgs-substitutable:<attr>` — the narinfo query for unstable's store path,
  `404` = still broken, `200` = someone built it. Nothing runs these yet (the daily agent
  is ADR-0038's, tracked in palimpsest#226), so today the probe is what *you* run on the
  day you wonder; a hold without one is a hold nobody will recheck.
- **The human release condition.** What has to be true before *you* unpin, in a sentence.
- **What was tried and rejected.** The expensive knowledge in a hold is the negative
  result. *snapcast 0.35.0 was tried and broke Music Assistant's teardown path* is worth
  more than the pin itself, because without it the next person re-pins blind or walks
  into the same wall.

Only holds that **can eventually become false** belong there. porcupineFish needing a
`stable_*` vendor kernel and `jmap-bridge` tracking a release tag are standing laws — no
upstream event makes them false, a daily probe on them can never pay, and they stay where
they already are (`AGENTS.md`, the host README, ADR-0016).

### One more thing a pin needs: an actual build

Every entry in `stable-until-fixed` takes the package from one pin and leaves its NixOS
module on another. That skew has bitten this repo before — a stable *package* under an
unstable *module* failed at eval because the module read a `passthru` only the newer
package had. So after pinning, **build the host**, don't just evaluate it.

## 5. Releasing a hold

A probe trips, or you decide to retest. Drop the pin, remove the `# HOLD:` comment, and
build the affected host — a `404` narinfo on the unstable path means it is still broken
and the pin goes back.

If it builds and deploys: **move the hold to the `## Cleared` section of `holds.md`, do
not delete it.** Record the date and what cleared it. Then name it under **Released** in
the changelog entry.

## 6. Write the changelog entry and commit

[`CHANGELOG.md`](../../CHANGELOG.md) gets one entry per bump, dated, in the **bump
commit** — not a follow-up. It admits only fleet-visible change; the test is *would I
want to know this when something behaves oddly next month?* Refactors, checks and docs
are `git log`'s job.

Link the `holds.md` anchors this bump opened or closed; don't restate them.

Stage explicit paths — never `git add -A`, the pre-commit hook re-stages untracked files
after you unstage them and a blanket add can swallow parallel work:

```console
$ git add flake.lock CHANGELOG.md docs/holds.md modules/shared/overlays/default.nix
$ git commit
$ git show --stat HEAD
```

`CHANGELOG.md` is **yours alone**, and stays that way when the daily holds agent is
built: it will write `holds.md` and nothing else — one owner per file is what makes an
automated writer safe next to a human editor (ADR-0038). Never hand it the changelog.

## Gotchas

- **A dirty working tree next door can fail your update.** Inputs fetched from a local
  path make Nix refuse to write the lock ("not writing lock file … unlocked input"). All
  the external repos are `git+ssh://` origins now for exactly this reason — if one ever
  points at a working copy again, this is the symptom.
- **`just switch` bumps `users` on its own**, with `--commit-lock-file`, so a local
  switch can produce a lock-only commit you did not ask for. That is deliberate; let it.
- **After a kernel-pin bump, re-run `just cache-kernel porcupineFish`** — otherwise the
  next deploy after a GC recompiles the kernel from source on rk1b
  ([`hosts/porcupineFish/README.md`](../../hosts/porcupineFish/README.md)).

## Related

- [`docs/holds.md`](../holds.md) — the registry, and the closed probe vocabulary
- [`CHANGELOG.md`](../../CHANGELOG.md) — the narrative half
- [ADR-0038](../adr/0038-held-back-packages-are-a-registry-an-agent-rechecks.md) — why a
  markdown registry and not a Nix attrset
- `flake.nix` — every pin's full reasoning and exit condition
- `AGENTS.md` → *Operational gotchas* — the traps that are not bump-specific
- [`hosts/porcupineFish/README.md`](../../hosts/porcupineFish/README.md) — the kernel pin
