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
# This mirrors the production music topology (rk1b -> kelpy, ADR-0027):
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
    # `push`. If the assistants are working, this is all a user ever has to do.
    source.succeed("sudo -u git-annex bash -c 'echo autonomous-payload > ${repoPath}/track.txt'")

    # The history must reach the replica by itself...
    replica.wait_until_succeeds(
        "sudo -u git-annex git -C ${repoPath} log --oneline --all | grep -q . ", timeout=180
    )

    # ...and so must the content: the file must exist in the replica's worktree.
    replica.wait_for_file("${repoPath}/track.txt", timeout=180)
    replica.wait_until_succeeds(
        "sudo -u git-annex grep -q autonomous-payload ${repoPath}/track.txt", timeout=180
    )

    # THE POINT of unlock+thin: a REAL file, not a symlink into .git/annex/objects,
    # and hardlinked to the object rather than a second copy (1x disk).
    replica.succeed("test -f ${repoPath}/track.txt")
    replica.fail("test -L ${repoPath}/track.txt")
    links = replica.succeed("stat -c %h ${repoPath}/track.txt").strip()
    assert links == "2", f"thin: worktree file should be hardlinked to the annex object (2 links), got {links}"

    # git-annex agrees the replica really holds the content, not just the history.
    whereis = source.succeed("sudo -u git-annex git -C ${repoPath} annex whereis track.txt")
    assert "replica" in whereis, f"source should see the replica holding a copy: {whereis!r}"

    # And a deletion propagates the same way — again with no manual sync.
    source.succeed("sudo -u git-annex rm ${repoPath}/track.txt")
    replica.wait_until_fails("test -e ${repoPath}/track.txt", timeout=180)
  '';
}
