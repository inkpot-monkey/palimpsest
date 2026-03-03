{ pkgs, ... }:

pkgs.testers.nixosTest {
  name = "git-annex-hybrid";
  nodes = {
    gateway =
      { pkgs, ... }:
      {
        imports = [ ../default.nix ];

        users.users.paperless = {
          isSystemUser = true;
          group = "paperless";
          createHome = true;
          home = "/var/lib/paperless";
        };
        users.groups.paperless = { };

        services.git-annex = {
          enable = true;
          repositories = {
            # 1. Hybrid Remote Test Repo
            main = {
              path = "/var/lib/git-annex/main";
              description = "main";
              remotes = [
                {
                  name = "backup";
                  url = "git-annex@backup:/var/lib/git-annex/backup";
                  type = "rsync"; # Hybrid: Git URL + Rsync Type
                  encryption = "none";
                }
              ];
            };

            # 2. Service Integration Test Repo
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
        networking.firewall.allowedTCPPorts = [ 22 ];
        services.openssh.enable = true;
        environment.systemPackages = [
          pkgs.git
          pkgs.git-annex
        ];
      };

    backup =
      { ... }:
      {
        imports = [ ../default.nix ];
        services.git-annex = {
          enable = true;
          repositories.backup = {
            path = "/var/lib/git-annex/backup";
            description = "backup";
          };
        };
        networking.firewall.allowedTCPPorts = [ 22 ];
        services.openssh.enable = true;
      };
  };

  testScript = ''
    start_all()

    # Wait for SSH
    gateway.wait_for_unit("sshd")
    backup.wait_for_unit("sshd")

    # Exchange keys for Hybrid Remote Test
    gateway.wait_for_file("/var/lib/git-annex/.ssh/id_ed25519.pub")
    key = gateway.succeed("cat /var/lib/git-annex/.ssh/id_ed25519.pub")
    backup.succeed(f"mkdir -p /var/lib/git-annex/.ssh && echo '{key}' >> /var/lib/git-annex/.ssh/authorized_keys && chown git-annex:git-annex /var/lib/git-annex/.ssh/authorized_keys")

    # Disable strict host checking
    gateway.succeed("mkdir -p /var/lib/git-annex/.ssh && echo 'Host *\n  StrictHostKeyChecking no\n' > /var/lib/git-annex/.ssh/config && chown git-annex:git-annex /var/lib/git-annex/.ssh/config")

    # Restart init service now that keys are present (it likely failed on boot)
    gateway.succeed("systemctl restart git-annex-init-main")

    # 1. Verify Hybrid Remote Initialization
    # The 'backup' remote should be a git remote AND a special remote

    # Check Git Remote
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/main remote | grep backup")

    # Check Special Remote (should be named backup-content)
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/main annex info backup-content | grep 'type: rsync'")

    # Verify rsyncurl is set correctly (mapped from url)
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/main annex info backup-content | grep 'url: git-annex@backup:/var/lib/git-annex/backup'")

    # 2. Verify Service Integration (Paperless)

    # Check permissions
    gateway.succeed("ls -ld /var/lib/paperless/media | grep paperless")

    # Create a file as paperless user
    gateway.succeed("sudo -u paperless bash -c 'cd /var/lib/paperless/media && echo document > doc.txt'")

    # Debug: Check if assistant service is running
    gateway.succeed("systemctl status git-annex-assistant-paperless >&2")

    # Debug: Check logs
    gateway.succeed("journalctl -u git-annex-assistant-paperless --no-pager >&2")

    # Wait for assistant to commit and tag it
    gateway.wait_for_file("/var/lib/paperless/media/.git/annex")

    # Give the assistant a moment to run the post-commit hook
    gateway.succeed("sleep 5")

    # Verify tag
    tags = gateway.succeed("sudo -u paperless git -C /var/lib/paperless/media annex metadata doc.txt --get tag")
    if "paperless" not in tags:
        raise Exception(f"File was not auto-tagged! Tags: {tags}")
        
    print("SUCCESS: Hybrid remote and Service integration verified.")
  '';
}
