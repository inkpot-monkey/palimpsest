# Coverage for the shared-group topology the music library needs (rk1b, ADR-0027):
# the repository is owned by a *different* user than the `git-annex` user that
# git-annex-shell runs as when a peer syncs in over SSH. On rk1b the library is
# written by beets/Navidrome (user `navidrome`, here `libowner`), while kelpy
# arrives as `git-annex@rk1b` — the module hardcodes the fleet key onto the
# `git-annex` user, so the SSH peer identity is not negotiable.
#
# Without a setgid repository directory the objects the peer writes land in the
# peer's own primary group (`git-annex`) and the owning service cannot read them,
# which silently breaks "library replicates both ways". This test pins:
#   - `mode` actually reaches the repo directory (2770, setgid bit set),
#   - `ownerGroup` is honoured alongside a non-default `user`,
#   - a file synced IN over SSH — written by the git-annex user, not the owner —
#     inherits the shared group via setgid and is readable by the owning user.
{ pkgs, ... }:
let
  helper = import ./lib.nix { inherit pkgs; };
  libraryPath = "/var/cache/music";
  sharedGroup = "music";

  # The library node's identity setup: a shared group that both the owning user
  # and the SSH peer (`git-annex`) belong to. This mirrors what hosts/rk1b needs.
  sharedGroupNode = _: {
    users.groups.${sharedGroup} = { };
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
  name = "git-annex-shared-group";
  nodes = {
    library =
      { ... }:
      {
        imports = [
          helper.commonNode
          sharedGroupNode
        ];

        # Required whenever the repo `user` differs from the SSH peer identity:
        # an inbound sync runs git-receive-pack as `git-annex` against a tree
        # owned by libowner, and git's dubious-ownership check refuses to touch
        # it ("detected dubious ownership in repository").
        #
        # `programs.git.enable = true` is load-bearing, not decoration:
        # programs.git.config only writes /etc/gitconfig under `mkIf cfg.enable`,
        # so declaring safe.directory without it is silently a no-op. (That is
        # exactly the state hosts/kelpy/git-annex.nix is in — its safe.directory
        # never reaches disk, and only goes unnoticed because that repo's user
        # *is* git-annex, so ownership matches and the check never fires.)
        programs.git.enable = true;
        programs.git.config.safe.directory = [
          libraryPath
          "${libraryPath}/.git"
        ];

        services.git-annex.repositories.music = {
          path = libraryPath;
          description = "library";
          user = "libowner";
          ownerGroup = sharedGroup;
          mode = "2770";
          shared = true;
          wanted = "standard";
        };
      };

    sharer =
      { ... }:
      {
        imports = [ helper.commonNode ];
        services.git-annex.repositories.music = {
          path = "/var/lib/git-annex/music";
          description = "sharer";
          remotes = [
            {
              name = "origin";
              url = "git-annex@library:${libraryPath}";
            }
          ];
        };
      };
  };

  testScript = ''
    start_all()

    library.wait_for_unit("git-annex-init-music.service")
    sharer.wait_for_unit("git-annex-init-music.service")

    # `mode` reaches the directory: setgid bit set, owned by the non-default user
    # and the shared group. 2770 is what makes the group inheritance below work.
    perms = library.succeed("stat -c '%a %U %G' ${libraryPath}").strip()
    assert perms == "2770 libowner music", f"expected '2770 libowner music', got '{perms}'"

    # The repo really did initialize under the owning user.
    library.succeed("test -d ${libraryPath}/.git")

    # Push a file from the sharer. On the library this is received by
    # git-annex-shell/git-receive-pack running as the `git-annex` user — NOT as
    # libowner — and the worktree is updated via receive.denyCurrentBranch=updateInstead.
    sharer.succeed("sudo -u git-annex bash -c 'cd /var/lib/git-annex/music && echo track > track.txt'")
    sharer.succeed("sudo -u git-annex git -C /var/lib/git-annex/music add .")
    sharer.succeed("sudo -u git-annex git -C /var/lib/git-annex/music commit -m 'add track'")
    sharer.succeed("sudo -u git-annex git -C /var/lib/git-annex/music push origin master --force")

    library.wait_for_file("${libraryPath}/track.txt")

    # THE POINT: the peer wrote this file as the `git-annex` user, whose primary
    # group is `git-annex`. Setgid on the repo dir must have forced it into the
    # shared `music` group instead — otherwise the owning service can't read it.
    group = library.succeed("stat -c '%G' ${libraryPath}/track.txt").strip()
    assert group == "music", f"file synced in over SSH landed in group '{group}', not 'music' — setgid did not apply"

    # And the owning user can actually read what the peer delivered.
    library.succeed("sudo -u libowner test -r ${libraryPath}/track.txt")
    library.succeed("sudo -u libowner cat ${libraryPath}/track.txt | grep -q track")

    # The owning user can still create files in the shared tree (dir is group-writable).
    library.succeed("sudo -u libowner touch ${libraryPath}/from-owner.txt")
    owner_group = library.succeed("stat -c '%G' ${libraryPath}/from-owner.txt").strip()
    assert owner_group == "music", f"owner-created file landed in group '{owner_group}', not 'music'"
  '';
}
