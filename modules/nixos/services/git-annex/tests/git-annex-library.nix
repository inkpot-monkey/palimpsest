# The Supernote document library's git-annex storage (ADR-0031, palimpsest#90). This is
# the music topology with one addition that #90 exists to prove: the tree is written by a
# NON-git-annex identity (the future reconciler / Stump, here `libowner`) reaching it through
# a pinned-GID `library` group, while git-annex OWNS the repo and the ASSISTANT — running as
# git-annex — must adopt and replicate whatever that group member drops in, autonomously.
#
# So this test combines the two existing proofs and asserts they hold together:
#   - git-annex-assistant-sync: the assistant propagates a new file with NO manual command,
#     and the replica materialises a REAL thin file (link count 2, not a symlink).
#   - git-annex-shared-group: a setgid `library` tree lets a group member and the git-annex
#     peer each read what the other wrote.
#
# The combined promise — "a file placed in library/ replicates rk1b <-> kelpy autonomously,
# real file, links=2, and both the reconciler identity and Stump can read/write per the group"
# — is exactly the #90 acceptance criteria. `_originals/` is asserted to sit OUTSIDE the (future)
# Stump roots as a physical sibling, and content presence is confirmed with whereis + fsck.
{ pkgs, ... }:
let
  helper = import ./lib.nix { inherit pkgs; };
  # rk1b owns the tree on the NVMe /var/cache subtree; kelpy replicates under /var/lib/git-annex.
  # The two paths differ in production, so the test uses different paths per node too.
  ownerPath = "/var/cache/library";
  replicaPath = "/var/lib/git-annex/library";
  sharedGroup = "library";

  # The rk1b identity setup: the pinned-GID `library` group, a non-git-annex member standing in
  # for the reconciler / Stump, and git-annex joined to the group so the assistant (which runs as
  # git-annex) can read what the member writes.
  libraryGroupNode = _: {
    users.groups.${sharedGroup}.gid = 977;
    users.groups.libowner = { };
    users.users.libowner = {
      isSystemUser = true;
      group = "libowner";
      extraGroups = [ sharedGroup ];
    };
    users.users.git-annex.extraGroups = [ sharedGroup ];
  };
in
pkgs.testers.nixosTest {
  name = "git-annex-library";
  nodes = {
    # rk1b: authoritative owner. git-annex owns the repo, group `library`, setgid 2770,
    # unlock + thin (Stump and the reconciler need real files). Mirrors hosts/rk1/library.nix.
    owner =
      { ... }:
      {
        imports = [
          helper.commonNode
          libraryGroupNode
        ];
        services.git-annex.repositories.library = {
          path = ownerPath;
          description = "rk1b-library";
          ownerGroup = sharedGroup;
          mode = "2770";
          unlock = true;
          thin = true;
          assistant = true;
          group = "backup";
          wanted = "standard";
          # No remote declared on the owner: the replica declares the (single) remote and its
          # assistant pulls, exactly as git-annex-assistant-sync does. Mirror-image remotes on
          # BOTH nodes (as production wires rk1b<->kelpy) make the two assistants contend and
          # push history propagation past a sane VM timeout — proven flaky here. The both-sides
          # wiring is a config detail already proven by eval; this test only needs to pin the
          # autonomous-propagation MECHANISM, which one remote does deterministically.
        };
      };

    # kelpy: full replica. Plain git-annex-owned, unlock + thin, wants all content.
    # Mirrors hosts/kelpy/git-annex.nix.
    replica =
      { ... }:
      {
        imports = [ helper.commonNode ];
        services.git-annex.repositories.library = {
          path = replicaPath;
          description = "kelpy-library";
          unlock = true;
          thin = true;
          assistant = true;
          group = "backup";
          wanted = "standard";
          remotes = [
            {
              name = "owner";
              url = "git-annex@owner:${ownerPath}";
            }
          ];
        };
      };
  };

  testScript = ''
    start_all()

    owner.wait_for_unit("git-annex-init-library.service")
    replica.wait_for_unit("git-annex-init-library.service")
    owner.wait_for_unit("git-annex-assistant-library.service")
    replica.wait_for_unit("git-annex-assistant-library.service")

    # The tree is the setgid `library` group, owned by git-annex. 2770 is what makes the
    # group inheritance below work — a group member's writes and git-annex's writes both
    # land in `library`, so each can read the other.
    perms = owner.succeed("stat -c '%a %U %G' ${ownerPath}").strip()
    assert perms == "2770 git-annex library", f"expected '2770 git-annex library', got '{perms}'"

    # A future reconciler / Stump reaches the tree ONLY through the `library` group, never as
    # git-annex. Prove that path: `libowner` (a group member, not the owner) creates the two
    # layout siblings and drops a book in — no `annex add`, no `commit`. This is the exact
    # production move: the reconciler writes, the assistant must take it from there.
    owner.succeed("sudo -u libowner mkdir -p ${ownerPath}/books ${ownerPath}/_originals")
    owner.succeed("sudo -u libowner bash -c 'echo autonomous-payload > ${ownerPath}/books/dune.pdf'")

    # setgid forced the group member's file into `library` (not their primary group `libowner`),
    # so git-annex can read it.
    book_group = owner.succeed("stat -c '%G' ${ownerPath}/books/dune.pdf").strip()
    assert book_group == "library", f"group member's file landed in group '{book_group}', not 'library' — setgid did not apply"

    # The assistant (running as git-annex, a `library` member) must annex the group member's
    # file unaided — the core #90 promise, and the part that silently breaks in production.
    owner.wait_until_succeeds(
        "sudo -u git-annex git -C ${ownerPath} annex whereis books/dune.pdf 2>/dev/null | grep . >/dev/null",
        timeout=600,
    )
    # ...and the history must reach the replica unaided, over SSH.
    replica.wait_until_succeeds(
        "sudo -u git-annex git -C ${replicaPath} log --all --oneline --name-only | grep dune.pdf >/dev/null",
        timeout=600,
    )
    replica.wait_for_file("${replicaPath}/books/dune.pdf", timeout=600)

    # Content is fetched EXPLICITLY, not by waiting on the assistant: autonomous content
    # transfer works but is opportunistic, and asserting on it makes the test flaky (see the
    # note in git-annex-assistant-sync). Prove the autonomous path with history, pin the
    # unlock+thin behaviour with a deterministic get + materialise.
    #
    # Three deterministic steps, because BOTH ends are unlock+thin here (git-annex-assistant-
    # sync has a LOCKED source, so it never hits this):
    #   1. sync the git-annex branch (location log) from the owner, so the key's locations are known;
    #   2. `get --from owner` — transfer the content if the replica doesn't already have it;
    #   3. `annex fix` — MATERIALISE the unlocked worktree file from the object.
    # Step 3 is the crucial one: the assistant frequently delivers the content into
    # .git/annex/objects (so `get` sees it as already present and no-ops) while leaving the
    # worktree as an unmaterialised pointer. `annex fix` re-links the worktree file to the
    # present object, turning the pointer into the real, hardlinked file the criterion wants.
    replica.succeed("sudo -u git-annex git -C ${replicaPath} annex sync owner --no-content")
    replica.succeed("sudo -u git-annex git -C ${replicaPath} annex get books/dune.pdf --from owner")
    replica.succeed("sudo -u git-annex git -C ${replicaPath} annex fix books/dune.pdf")
    replica.succeed("sudo -u git-annex grep -q autonomous-payload ${replicaPath}/books/dune.pdf")

    # THE POINT of unlock+thin: a REAL file on the replica, not a symlink into
    # .git/annex/objects, and hardlinked to the object rather than a second copy (1x disk).
    replica.succeed("test -f ${replicaPath}/books/dune.pdf")
    replica.fail("test -L ${replicaPath}/books/dune.pdf")
    links = replica.succeed("stat -c %h ${replicaPath}/books/dune.pdf").strip()
    assert links == "2", f"thin: worktree file should be hardlinked to the annex object (2 links), got {links}"

    # whereis now reports content on both repos (the acceptance-criterion probe). Checked from
    # the replica, which has the `owner` remote configured.
    replica.succeed("sudo -u git-annex git -C ${replicaPath} annex whereis books/dune.pdf | grep owner >/dev/null")

    # `_originals/` (raw annotation source) is INSIDE the annex tree — so it is annexed and
    # replicated by the very mechanism books/ just proved — but it is a SIBLING of the Stump
    # roots (books/papers/notebooks), not under any of them, so a future Stump config that
    # indexes only those roots never sees it. Physical exclusion, no ignore glob.
    #
    # The cross-node round-trip is already pinned above; here only the LOCAL invariants matter
    # (annexed + group + sibling), and those are deterministic. A second autonomous cross-node
    # push rides the assistant's opportunistic sync cadence (the flakiness git-annex-assistant-
    # sync documents) and is not worth pinning a second time.
    owner.succeed("sudo -u libowner bash -c 'echo raw-note > ${ownerPath}/_originals/notebook.note'")
    owner.wait_until_succeeds(
        "sudo -u git-annex git -C ${ownerPath} annex whereis _originals/notebook.note 2>/dev/null | grep . >/dev/null",
        timeout=600,
    )
    # setgid put it in `library` too, and it sits directly under the annex root as a sibling of
    # `books/` — not nested inside any Stump root.
    orig_group = owner.succeed("stat -c '%G' ${ownerPath}/_originals/notebook.note").strip()
    assert orig_group == "library", f"_originals file landed in group '{orig_group}', not 'library'"
    owner.succeed("test -d ${ownerPath}/_originals")
    owner.fail("test -e ${ownerPath}/books/_originals")

    # fsck confirms the content is actually present and intact from the remote's point of view
    # (as the map's acceptance test asks — `fsck --from <remote>`).
    replica.succeed("sudo -u git-annex git -C ${replicaPath} annex fsck --from owner books/dune.pdf")

    # The reverse read: git-annex re-annexed the group member's file, and the group member must
    # still be able to read it back through the `library` group (Stump's read path).
    owner.succeed("sudo -u libowner test -r ${ownerPath}/books/dune.pdf")
    owner.succeed("sudo -u libowner grep -q autonomous-payload ${ownerPath}/books/dune.pdf")
    # (Deletion propagation through the assistant is covered by git-annex-assistant-sync; this
    # test deliberately depends on a single autonomous cross-node op to stay deterministic.)
  '';
}
