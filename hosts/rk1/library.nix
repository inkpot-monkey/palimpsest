# rk1b's Supernote document library as a git-annex repository — the corpus tree holding the
# handwriting the Supernote mirror materialises (palimpsest#117) and the books/papers Stump
# indexes (palimpsest#93), replicated to kelpy. This once said "the bidirectional reconciler
# (palimpsest#94) writes"; #94 is closed and there is no upward path any more, so the mirror is
# the only writer of `supernote/`.
#
# UNLIKE the music library these are personal documents, not re-acquirable media, so ADR-0031
# also asks that they be backed up OFFSITE. ⚠ That half is INTENT, NOT FACT: no restic path
# lists this tree, `backup.enable = false` on every host that sets it, and rk1b runs no restic
# unit at all (palimpsest#147). Do not read this header as evidence the documents are backed
# up — they are REPLICATED, which is the weaker guarantee: it survives a dead disk, but not a
# delete propagating to both copies, nor losing the house.
#
# The storage / placement / backup decision is ADR-0031 (built by palimpsest#90); it deliberately
# reuses the ADR-0028 git-annex ownership model (read that before changing the ownership here).
#
# Imported by rk1b only (hosts/default.nix), ALONGSIDE hosts/rk1/git-annex.nix, which
# already enables services.git-annex and installs the annex SSH identity + sops key. This
# file only ADDS the `library` repository, the pinned-GID `library` group, and the
# git-annex user's membership in it. It deliberately does NOT re-set `enable` / `sshKeyFile`
# / the sops secret — those are single-value options and a second definition would conflict;
# `repositories` and `extraGroups` merge across modules, so contributing the repo here is safe.
{
  config,
  settings,
  ...
}:
{
  # This file only ADDS a repository; hosts/rk1/git-annex.nix is what enables the module and
  # installs the annex identity/sops key. Guard the pairing (as git-annex.nix guards Navidrome):
  # without that import, `services.git-annex.enable` is false, the module's config is gated off,
  # and this `library` repository silently never initialises instead of failing loudly.
  assertions = [
    {
      assertion = config.services.git-annex.enable;
      message = "hosts/rk1/library.nix adds a `library` repository to services.git-annex, but the module is not enabled — import hosts/rk1/git-annex.nix alongside this file (see hosts/default.nix), or drop this import.";
    }
  ];

  # The pinned-GID sharing group. git-annex OWNS the tree (only the git-annex user holds the
  # fleet annex SSH key, so the replicating node must own what it replicates — same reasoning
  # as `music`, ADR-0028); the reconciler and Stump reach the tree as members of this group.
  #
  # GID is pinned deliberately: the tree's group ownership lives on persistent NVMe, and an
  # auto-allocated GID reshuffle would orphan every file's group in place (this fleet has been
  # bitten by exactly that — see [[kelpy-uid-map-drift]]). 977 is free fleet-wide and unclaimed
  # by any other pinned id here (music=978, stalwart-mail=981, openclaw=987).
  users.groups.library.gid = 977;

  # git-annex joins `library` so the tree it owns is group-readable to future members (the
  # Supernote mirror, Stump) and — via the setgid mode below — its own inbound-sync writes land
  # in `library` too, readable by them. Merges with the `music` membership hosts/rk1/git-annex.nix
  # adds (list options concatenate across modules).
  users.users.git-annex.extraGroups = [ "library" ];

  services.git-annex.repositories.library = {
    # On the durable NVMe /var/cache subtree (hosts/rk1/nvme.nix), like the music library and
    # the beets pipeline — survives the tmpfs-root reboot. The annex ROOT is this directory;
    # `books/`, `papers/`, `notebooks/` (the three Stump roots, #93) and `_originals/` (raw
    # `.note`/`.mark`, the precious annotation source) are siblings inside it — so `_originals/`
    # is outside every Stump root by PHYSICAL placement, needing no ignore glob to survive a
    # Stump DB rebuild.
    path = "/var/cache/library";
    description = "rk1b-library";

    # `user` left at the default (git-annex): the repo owner and the SSH peer identity are the
    # same user, so — as with music on rk1b — `.git` needs no group-write and git's dubious-
    # ownership check never fires (no `shared`, no `safe.directory` needed).
    ownerGroup = "library";
    # setgid: everything any identity creates in the tree inherits `library`, so the mirror's
    # writes stay reachable by git-annex and git-annex's inbound-sync writes stay readable by the
    # mirror and Stump. Same seam as music's 2770.
    mode = "2770";

    # rk1b is authoritative and owns the tree; the assistant adopts whatever the mirror
    # writes without waiting for a timer. `unlock` + `thin` so the working tree holds REAL,
    # editable files hardlinked to the annex object (1x disk) — Stump and the mirror need
    # real files, not symlinks into .git/annex/objects.
    unlock = true;
    thin = true;
    assistant = true;

    # rk1b and kelpy both want every file (rk1b authoritative, kelpy full replica).
    # ⚠ `backup` here is a git-annex REPOSITORY GROUP (paired with `wanted` below) — it means
    # "this remote wants every file", i.e. content distribution between rk1b and kelpy. It is NOT
    # an offsite backup and does not make one run; palimpsest#147 names this exact misreading.
    group = "backup";
    wanted = "standard";

    # rk1b initiates; kelpy declares the mirror-image remote (hosts/kelpy/git-annex.nix). A
    # MagicDNS name via settings.tailnet, not a pinned IP (which rots on re-key) and not the
    # bare hostname (rk1b can't resolve `kelpy`) — the same rule the music remote follows.
    remotes = [
      {
        name = "kelpy";
        url = "git-annex@kelpy.${settings.tailnet}:/var/lib/git-annex/library";
      }
    ];
  };
}
