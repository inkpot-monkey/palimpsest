{ pkgs, ... }:

let
  helper = import ./lib.nix { inherit pkgs; };
in
pkgs.testers.nixosTest {
  name = "git-annex-hybrid";
  nodes = {
    gateway =
      { ... }:
      {
        imports = [ helper.commonNode ];

        users.users.paperless = {
          isSystemUser = true;
          group = "paperless";
          createHome = true;
          home = "/var/lib/paperless";
        };
        users.groups.paperless = { };

        services.git-annex.repositories = {
          # 1. Hybrid remote (git URL + rsync content) test repo
          main = {
            path = "/var/lib/git-annex/main";
            description = "main";
            remotes = [
              {
                name = "backup";
                url = "git-annex@backup:/var/lib/git-annex/backup";
                type = "rsync"; # Hybrid: git URL + rsync type
                encryption = "none";
              }
            ];
          };

          # 2. Service integration: a repo owned by a different user, auto-tagging
          paperless = {
            path = "/var/lib/paperless/media";
            description = "paperless-media";
            user = "paperless";
            ownerGroup = "paperless";
            assistant = true;
            tags = [ "paperless" ];
            wanted = "metadata=tag=paperless";
          };
        };
      };

    backup =
      { ... }:
      {
        imports = [ helper.commonNode ];
        services.git-annex.repositories.backup = {
          path = "/var/lib/git-annex/backup";
          description = "backup";
        };
      };
  };

  testScript = ''
    start_all()

    gateway.wait_for_unit("git-annex-init-main.service")
    gateway.wait_for_unit("git-annex-init-paperless.service")

    # 1. Hybrid remote: 'backup' is both a git remote and a special remote.

    # Git remote
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/main remote | grep backup")

    # Special remote, named backup-content to avoid the git-remote name clash
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/main annex info backup-content | grep 'type: rsync'")

    # rsyncurl was mapped from the configured url
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/main annex info backup-content | grep 'url: git-annex@backup:/var/lib/git-annex/backup'")

    # 2. Service integration (paperless): different owner, auto-tagging.
    gateway.succeed("ls -ld /var/lib/paperless/media | grep paperless")

    # Create a file as the paperless user; the assistant commits it.
    gateway.succeed("sudo -u paperless bash -c 'cd /var/lib/paperless/media && echo document > doc.txt'")

    # Wait for the assistant to commit, then for the post-commit hook to tag.
    gateway.wait_for_file("/var/lib/paperless/media/.git/annex")
    gateway.wait_until_succeeds(
        "sudo -u paperless git -C /var/lib/paperless/media annex metadata doc.txt --get tag | grep paperless"
    )

    print("SUCCESS: Hybrid remote and service integration verified.")
  '';
}
