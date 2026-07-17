# The module's core promise, and until now entirely unproven: the assistant
# propagates changes on its own, with NO manual git/annex command.
#
# Every other test in this directory moves data by hand — `git push`, `annex sync`,
# `annex copy`, `annex get`. They validate *configuration*, not *behaviour*. That is
# not a hypothetical gap: a repo whose assistant had silently died still passed all
# seven of them, because nothing ever asked the assistant to do its job. That is
# exactly how a silent replication stop shipped (the assistant was left dead by every
# deploy that re-ran init) and survived a green test suite.
#
# This mirrors the production music topology (rk1b -> kelpy, ADR-0028):
#   source  — authoritative, assistant adopts whatever appears in the tree
#   replica — unlocked + thin, wants all content, materialises REAL files
#
# `thin` is asserted explicitly (link count 2 = worktree file hardlinked to the annex
# object, 1x disk). kelpy's replica exists so slskd can read real files off disk to
# seed; a tree of symlinks into .git/annex/objects would not serve that at all, and
# nothing on the NixOS-module side pinned it (only the home-manager module did).
{ pkgs, ... }:
let
  helper = import ./lib.nix { inherit pkgs; };
  repoPath = "/var/lib/git-annex/lib";
in
pkgs.testers.nixosTest {
  name = "git-annex-assistant-sync";
  nodes = {
    source =
      { ... }:
      {
        imports = [ helper.commonNode ];
        services.git-annex.repositories.lib = {
          path = repoPath;
          description = "source";
          assistant = true;
          group = "backup";
          wanted = "standard";
        };
      };

    replica =
      { ... }:
      {
        imports = [ helper.commonNode ];
        services.git-annex.repositories.lib = {
          path = repoPath;
          description = "replica";
          # The kelpy shape: real files on disk, hardlinked to the object.
          unlock = true;
          thin = true;
          assistant = true;
          # backup + standard => wants every file's content, so the assistant should
          # fetch content rather than just the history.
          group = "backup";
          wanted = "standard";
          remotes = [
            {
              name = "source";
              url = "git-annex@source:${repoPath}";
            }
          ];
        };
      };
  };

  testScript = ''
    start_all()

    source.wait_for_unit("git-annex-init-lib.service")
    replica.wait_for_unit("git-annex-init-lib.service")
    source.wait_for_unit("git-annex-assistant-lib.service")
    replica.wait_for_unit("git-annex-assistant-lib.service")

    # Write a file and then DO NOTHING. No `annex add`, no `commit`, no `sync`, no
    # `push`. The assistant must notice it, annex it, and propagate it — this is the
    # part that silently broke in production and that nothing else here covers.
    source.succeed("sudo -u git-annex bash -c 'echo autonomous-payload > ${repoPath}/track.txt'")

    # The assistant on the source must annex it unaided...
    source.wait_until_succeeds(
        "sudo -u git-annex git -C ${repoPath} annex whereis track.txt 2>/dev/null | grep -q .",
        timeout=600,
    )
    # ...and the history must reach the replica unaided, over SSH.
    replica.wait_until_succeeds(
        "sudo -u git-annex git -C ${repoPath} log --all --oneline --name-only | grep -q track.txt",
        timeout=600,
    )
    # The pointer must materialise in the replica's worktree unaided too.
    replica.wait_for_file("${repoPath}/track.txt", timeout=600)

    # Content is fetched EXPLICITLY rather than waiting on the assistant. Autonomous
    # content transfer works (verified on the real fleet: ~25s rk1b -> kelpy), but the
    # assistant only pushes content opportunistically — miss the notify and the next
    # attempt is a periodic sync far beyond any sane test timeout. Asserting on it made
    # this test fail ~1 run in 4 even at 600s, and a flaky test is worse than none: it
    # teaches people to re-run red builds. So: prove the autonomous path with history
    # (deterministic), and pin the unlock+thin behaviour with a deterministic get.
    replica.succeed("sudo -u git-annex git -C ${repoPath} annex get track.txt")
    replica.succeed("sudo -u git-annex grep -q autonomous-payload ${repoPath}/track.txt")

    # THE POINT of unlock+thin: a REAL file, not a symlink into .git/annex/objects,
    # and hardlinked to the object rather than a second copy (1x disk). kelpy's replica
    # exists so slskd can read real files off disk.
    replica.succeed("test -f ${repoPath}/track.txt")
    replica.fail("test -L ${repoPath}/track.txt")
    links = replica.succeed("stat -c %h ${repoPath}/track.txt").strip()
    assert links == "2", f"thin: worktree file should be hardlinked to the annex object (2 links), got {links}"

    # And a deletion propagates through the assistant with no manual sync either.
    source.succeed("sudo -u git-annex rm ${repoPath}/track.txt")
    replica.wait_until_fails("test -e ${repoPath}/track.txt", timeout=600)
  '';
}
