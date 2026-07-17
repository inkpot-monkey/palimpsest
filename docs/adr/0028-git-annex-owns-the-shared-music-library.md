# git-annex owns the shared music library, and services reach it through a group

ADR-0027 put the friends' Navidrome library on rk1b at `/var/cache/music`, written
by the beets importer and read by Navidrome — a directory owned by, and private to,
`navidrome` (`0700`). The other half of that plan is sharing the library back out:
kelpy needs a full copy so slskd can seed it on Soulseek, which means the library
becomes a **git-annex repository replicated rk1b → kelpy**. That forces a question
ADR-0027 never had to answer: when two identities must write one tree, who owns it?

The plan's original answer was "navidrome owns it; git-annex joins the group". That
turns out to be unimplementable as a *replicating* library, for a reason that is not
obvious from the module's options: the module installs the fleet annex SSH key into
`/var/lib/git-annex/.ssh/` (`0600`, inside a `0700` dir owned by `git-annex`), so a
repository whose `user` is anyone else **can never sync outbound** — it can only
receive. The authoritative node is precisely the one that must push, so the original
design quietly demotes rk1b to a passive server and makes kelpy poll to discover new
music. It also made the plan self-contradictory: it declared rk1b's ability to
decrypt the annex key "THE BLOCKER", while its own topology meant rk1b never needed
that key at all.

## Decision

**The `git-annex` system user owns the library tree, and Navidrome and beets reach it
through a dedicated `music` group.** On rk1b `/var/cache/music` is `2770 git-annex:music` (setgid), `git-annex` and `navidrome` both join `music`, and the
beets importer runs `Group=music` with `UMask=0002`.

- **Ownership follows the key.** The replicating node must own what it replicates,
  because only the owner can use the annex identity. Ownership and sync-direction
  stay independent: this *enables* rk1b to push without requiring it, so kelpy-pulls
  remains available. The rejected design forecloses the option permanently.
- **Navidrome loses nothing by not owning it.** Upstream places `MusicFolder` in
  `BindReadOnlyPaths` — Navidrome only ever *reads* the library. Its supplementary
  `music` group survives the unit's `PrivateUsers=true` sandbox (verified on the host,
  not assumed), so group access is sufficient.
- **setgid is load-bearing, not decoration.** Whichever identity creates a file, the
  other must be able to use it. Without setgid, files written by the SSH peer land in
  `git-annex`'s own primary group and the library service cannot read them. `UMask=0002`
  is its twin: `git annex add` *moves* a file into `.git/annex/objects`, and a rename
  needs write on the containing directory — with the default `022` the Artist/Album
  dirs beets creates are `0755`, the move fails, and tracks sit in the library
  un-annexed and never replicate.
- **The `music` group's GID is pinned (978).** The library's group ownership lives on
  persistent disk; an auto-allocated GID reshuffle would orphan every file in place.

**kelpy holds an `unlock` + `thin` replica** at `/var/lib/git-annex/music`: real files
hardlinked to the annex objects (1× disk), because slskd must read actual bytes off
disk to seed them — a tree of symlinks into `.git/annex/objects` would not serve.

## Rejected: teaching the module to hand the key to any repo's user

The tempting fix — "remove the limitation so any `user` can sync outbound" — is the
one option that makes things materially worse, and it would do so silently. There is
**one annex keypair for the entire fleet**: the module hardcodes a single public key
into `authorized_keys` on every annex host, so whoever holds the private key can SSH
as `git-annex@` *any* of them. Handing it to a repo's own user would place a
credential granting access to every annex repo — including kelpy's `pictures`, i.e.
personal photos — inside Navidrome, a network-facing web app serving accounts to
friends. The single-user confinement reads like an arbitrary limitation; it is in
fact a security boundary. Work *with* it, and fix the shared key properly instead:
tracked as palimpsest#58 (per-node keys with peer-derived `authorized_keys`).

## Consequences

- `/var/cache/music` relaxes from `0700 navidrome` to `2770 git-annex:music`. Free
  while the library is empty; do it before seeding music.
- The seam spans three files — the group is declared in `navidrome.nix` (the library's
  owner-concept), consumed by `beets.nix` and `hosts/rk1/git-annex.nix`. Both
  consumers assert Navidrome is enabled rather than silently misconfiguring.
- **The music replica must be excluded from off-site backup.** kelpy backs up
  `/persistent` wholesale and persists `/var/lib/git-annex` into it, so the replica is
  explicitly excluded in `hosts/kelpy/configuration.nix`. `pictures` alongside it is
  personal and stays backed up — do not widen the exclusion.
- Covered by `git-annex-shared-group` (the ownership/setgid seam) and
  `git-annex-assistant-sync` (autonomous propagation, and `thin` materialising real
  hardlinked files).
