# Backups enumerate what is irreplaceable; they never snapshot a machine

Until now the fleet's off-site jobs were written two different ways. rk1b named four Immich
subtrees and said in prose what it was leaving out. kelpy backed up `/persistent`; porcupineFish
backed up `/var/lib` and `/home/inkpotmonkey`; sawtoothShark's commented-out line said
`/persist`. The second form is the default anyone reaches for, and it is wrong here in a way
that is easy to state and easy to miss.

**Decision: a backup job names the trees that cannot be rebuilt, and every directory the host
persists must be classified — backed up, or declined in writing with the reason.**

## Why bulk fails, concretely

Not on taste. On four counts, each measured on this fleet:

**It cannot run.** sawtoothShark's `/home/inkpotmonkey` is **143 GiB** against a **112 GiB**
soft quota at rsync.net. The commented-out `paths = [ "/persist" ]` could never have completed
once. Of that 143 GiB, roughly **2 GiB** is irreplaceable: 18G is Steam, 12G is browser
profiles, 28G is package stores and model caches, 57G is `code` that is pushed to git, 14G is
Downloads.

**It defeats the tool.** `/var/log` churns every night, so it both inflates each snapshot and
gives restic's deduplication nothing to match. The cost recurs forever and buys a journal
nobody restores.

**It ships what should not travel.** Bulk paths on a workstation sweep up `~/.ssh` and
`~/.gnupg`. The restic password is one fleet-wide sops secret, so every host with the backup
profile can read the repository — which means a bulk backup here would, once palimpsest#150
reaches kelpy, put the admin SSH key where a headless agent host can read it. AGENTS.md
forbids shipping that key to agent hosts; a bulk backup does it sideways.

**It hides the question.** This is the one that cost us. `paths = [ "/persistent" ]` answers
"what matters here?" with "everything, I suppose", so nobody ever asks. The question stays
unasked right up until a restore.

## What the enumeration cost, and the hole it opened

Targeting has a real failure mode of its own, and it is worse than waste: **a service added
next year persists its state and nobody notices it is unprotected.** Bulk is safe-by-default;
enumeration is precise-by-default. Trading one for the other unimproved would be a bad deal.

So the decision has a second half. Impermanence already declares, exhaustively, every directory
a host keeps across reboots — an enumeration we did not have to invent. A job may therefore
name an `environment.persistence` root (`classifyPersistence`), and the build then **fails**
unless every directory under it is either covered by `paths` or listed in `notBackedUp` with a
reason. Adding a service that persists state fails the build until someone decides. The reason
strings are not decoration: they are what makes "we decided" distinguishable from "we forgot",
and a stale entry naming a directory the host no longer keeps fails too, so the list cannot rot
into a description of a machine that no longer exists.

Two assertions and a denylist of whole-machine roots (`/`, `/home`, `/var/lib`, `/persistent`,
…) express the rest. All of it is checked for **declared** jobs, not just enabled ones — kelpy
and sawtoothShark both carry jobs whose backups are still deferred, and a check that waited for
`enable = true` would be dormant for exactly the period in which the enumeration gets written
and forgotten. That is the mistake kelpy's own ADR-0031 exclude guard made.

## It found a live gap on its first run

The rule paid for itself immediately, which is the strongest argument available for it.

rk1b has been the fleet's only off-site job since 2026-10-05, uploading ~13 GiB of photos
nightly. Requiring it to classify its own persisted state surfaced a tree it had never named:
**`/var/cache/library`**, the git-annex Supernote document library (ADR-0031, palimpsest#90:
books, papers, notebooks, `_originals`), 26M of annex objects. palimpsest#150 names this the
**highest priority** of the whole backup rollout. The plan had it travelling off-site via
kelpy's replica — but kelpy's job is still deferred, and a replica is not a backup: two live
copies both follow a delete. It had **no off-site copy at all**.

It was not found by anything failing. It was found by a rule that refuses to let a directory go
unconsidered. The file that omitted it also *claimed* the photo library was "the only tree here
whose contents are neither re-acquirable nor replicated" — a comment that was wrong, and that no
test could contradict, because prose is not checked. Backing up the tree also completes an
intent ADR-0031 had already recorded: `supernote.nix` notes an orphan "would replicate to kelpy
(and offsite too, once this tree is backed up)".

**And the rule's first draft overreached, which an older guard caught.** That draft also added
`/var/lib/supernote` — the Supernote server store — on the reasoning that restoring the annex
tree without the device's index gives you files rather than a library. ADR-0031 had already
decided otherwise, and `custom.profiles.supernote` asserts it: the store is rebuildable from
the device and its live content is mirrored into `library/supernote`, which the new path
covers. The assertion refused the deploy, naming the ADR. Worth recording for two reasons: a
decision written down as an assertion stopped a plausible-sounding mistake months later, and
the new check initially missed it — it looked only for its own four messages, so it reported a
clean fleet while rk1b could not be deployed. It now requires every real host to evaluate with
**no** failing assertion at all.

## Consequences

**Per host, the answer differs, and one of them is "nothing".** porcupineFish persists nine
directories and not one earns an off-site copy: every one is either written by the flake or
re-authed in one command. Its job is therefore declared with **empty** `paths` and a complete
`notBackedUp` — the record of an audit rather than dead config — and it sets no `reportJobs`,
because a permanent OFF row on the Backups board would answer "is everything backed up?" with
"no, and someone should fix that" about a host that needs nothing.

**Reasons are unchecked where there is no impermanence root.** sawtoothShark has none, so its
`notBackedUp` is documentation only. Re-walk `~` by size when its job is enabled and when the
machine changes shape; the bulk-root denylist is the only automatic guard there.

**Changing `paths` starts a new retention group.** restic's `forget` groups by `host,paths`, so
rk1b's pre-existing snapshots now form a group of their own and age out under the same policy
rather than being extended. Expected, and worth knowing before reading `forget` output.

**Private key custody is now an open question, not an oversight.** `~/.ssh` and `~/.gnupg` are
excluded for the shared-repository reason above, which means they are backed up **nowhere**.
That is a decision to make deliberately — a separate single-host repository, an age-encrypted
copy in the stash, or offline media — and it is the one thing this ADR leaves open.
