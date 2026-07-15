{
  pkgs,
  inputs,
}:
let

  # Generate SSH keys dynamically
  sshKeys =
    pkgs.runCommand "ssh-keys"
      {
        nativeBuildInputs = [ pkgs.openssh ];
      }
      ''
        mkdir -p $out
        ssh-keygen -t ed25519 -f $out/id_ed25519 -N "" -C "test-key"
      '';
in
pkgs.testers.nixosTest {
  name = "git-annex-home-manager";
  nodes = {
    gateway =
      { ... }:
      {
        imports = [ (inputs.self + /modules/nixos/services/git-annex/default.nix) ];
        services.git-annex = {
          enable = true;
          repositories.gateway = {
            path = "/var/lib/git-annex/gateway";
            description = "gateway";
            assistant = true;
            # Want all content, like kelpy's `pictures` repo: this is what makes
            # the client's assistant push file *content* (not just the git
            # pointer) here, i.e. the actual backup.
            group = "backup";
            wanted = "standard";
          };
        };
        networking.firewall.allowedTCPPorts = [ 22 ];
        services.openssh.enable = true;
        users.users.git-annex.openssh.authorizedKeys.keys = [
          (builtins.readFile "${sshKeys}/id_ed25519.pub")
        ];
      };

    client =
      { pkgs, ... }:
      {
        imports = [ inputs.home-manager.nixosModules.home-manager ];

        users.users.alice = {
          isNormalUser = true;
          extraGroups = [ "wheel" ];
          openssh.authorizedKeys.keys = [ (builtins.readFile "${sshKeys}/id_ed25519.pub") ];
        };

        environment.systemPackages = [
          pkgs.git
          pkgs.git-annex
        ];

        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
        home-manager.users.alice =
          {
            ...
          }:
          {
            imports = [ ../default.nix ];
            # Inline debug to verify option setting
            config = {
              home.stateVersion = "24.05";
              programs.git = {
                enable = true;
                settings = {
                  user = {
                    name = "Alice";
                    email = "alice@example.com";
                  };
                };
              };
              services.git-annex = {
                enable = true;
                repositories = {
                  annex = {
                    path = "/home/alice/Annex";
                    description = "test-annex";
                    unlock = true;
                    remotes = [
                      {
                        name = "gateway";
                        url = "git-annex@gateway:/var/lib/git-annex/gateway";
                      }
                    ];
                  };
                };
                assistant.enable = false;
              };
            };
          };
      };
    client_full =
      { pkgs, ... }:
      {
        imports = [ inputs.home-manager.nixosModules.home-manager ];

        users.users.bob = {
          isNormalUser = true;
          extraGroups = [ "wheel" ];
          openssh.authorizedKeys.keys = [ (builtins.readFile "${sshKeys}/id_ed25519.pub") ];
        };

        environment.systemPackages = [
          pkgs.git
          pkgs.git-annex
        ];

        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
        home-manager.users.bob =
          {
            ...
          }:
          {
            imports = [ ../default.nix ];
            config = {
              home.stateVersion = "24.05";
              programs.git = {
                enable = true;
                settings = {
                  user = {
                    name = "Bob";
                    email = "bob@example.com";
                  };
                };
              };
              services.git-annex = {
                enable = true;
                repositories = {
                  annex = {
                    path = "/home/bob/Annex";
                    description = "bob-annex";
                    assistant = true;
                    tags = [ "hm" ];
                    remotes = [
                      {
                        name = "gateway";
                        url = "git-annex@gateway:/var/lib/git-annex/gateway";
                        type = "git";
                        cost = 50;
                      }
                      {
                        name = "backup";
                        type = "directory";
                        params = {
                          directory = "/home/bob/Backup";
                          encryption = "none";
                        };
                        # Selective preferred content: this remote only wants
                        # JPEGs. The test asserts a *.jpg's content lands here
                        # while other files' content does not.
                        wanted = "include=*.jpg";
                      }
                    ];
                  };
                };
                assistant.enable = true;
              };
            };
          };
      };
  };

  testScript = ''
    start_all()

    # Enable lingering for users
    client.succeed("loginctl enable-linger alice")
    client_full.succeed("loginctl enable-linger bob")

    # 1. Setup SSH keys
    for machine in [client, client_full]:
      machine.succeed("mkdir -p /home/alice/.ssh /home/bob/.ssh")
      # We only need keys for the specific user on each machine, but simpler to copy to both paths if they exist
      if machine == client:
        user="alice"
      else:
        user="bob"
      
      machine.succeed(f"mkdir -p /home/{user}/.ssh")
      machine.succeed(f"cp ${sshKeys}/id_ed25519 /home/{user}/.ssh/id_ed25519")
      machine.succeed(f"chmod 600 /home/{user}/.ssh/id_ed25519")
      machine.succeed(f"chown -R {user}:users /home/{user}/.ssh")

    # Create backup directory for bob
    client_full.succeed("mkdir -p /home/bob/Backup")
    client_full.succeed("chown bob:users /home/bob/Backup")

    # 2. Wait for Gateway

    gateway.wait_for_unit("git-annex-assistant-gateway.service")

    # 3. Wait for Client HM Activation
    client.wait_for_unit("user@1000.service")
    client_full.wait_for_unit("user@1000.service")

    # Wait for git-annex-init-annex user service. Poll for active|failed so a
    # failed oneshot raises immediately (with its journal) instead of polling
    # until the global test timeout.
    def wait_user_init(node, user):
        run = f"sudo -u {user} XDG_RUNTIME_DIR=/run/user/1000 "
        for _ in range(120):
            state = node.succeed(
                run + "systemctl --user is-active git-annex-init-annex.service || true"
            ).strip()
            if state == "active":
                return
            if state == "failed":
                node.succeed(run + "journalctl --user -u git-annex-init-annex.service --no-pager >&2 || true")
                raise Exception(f"git-annex-init-annex failed for {user}")
            node.sleep(1)
        node.succeed(run + "systemctl --user status git-annex-init-annex.service --no-pager >&2 || true")
        node.succeed(run + "journalctl --user -u git-annex-init-annex.service --no-pager >&2 || true")
        raise Exception(f"git-annex-init-annex did not become active for {user} (stuck activating)")

    wait_user_init(client, "alice")
    wait_user_init(client_full, "bob")

    # 4. Verify Assistant Service
    # Client: Should be disabled
    client.fail("systemctl --user is-active git-annex-assistant.service")
    client.fail("test -f /home/alice/.config/git-annex/autostart")

    # Client Full: Should be enabled
    # Verify autostart file exists first
    client_full.succeed("test -f /home/bob/.config/git-annex/autostart")
    client_full.succeed("grep '/home/bob/Annex' /home/bob/.config/git-annex/autostart")

    # Verify assistant service is active
    client_full.wait_until_succeeds("sudo -u bob XDG_RUNTIME_DIR=/run/user/1000 systemctl --user is-active git-annex-assistant.service")

    # Verify git config
    client.succeed("sudo -u alice GIT_PAGER=cat git config --list >&2")

    # Verify repo initialization
    client.succeed("test -d /home/alice/Annex/.git")
    client.succeed("sudo -u alice timeout 30s env GIT_PAGER=cat GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=no' git -C /home/alice/Annex annex info")

    client_full.succeed("test -d /home/bob/Annex/.git")

    # 7. Verify Remotes
    client.succeed("sudo -u alice git -C /home/alice/Annex remote | grep gateway")

    # Client Full: Verify special remote 'backup'
    client_full.succeed("sudo -u bob git -C /home/bob/Annex remote | grep gateway")
    # Check if special remote is known to annex
    client_full.succeed("sudo -u bob timeout 30s env GIT_PAGER=cat GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=no' git -C /home/bob/Annex annex info | grep 'backup'")

    # 9. Unlock Verification
    client.succeed("sudo -u alice touch /home/alice/Annex/test-file")
    client.succeed("test -f /home/alice/Annex/test-file")
    client.succeed("! test -L /home/alice/Annex/test-file")

    # 9b. Combined: an UNLOCKED client transfers a BINARY file over SSH to the
    # server, integrity verified end to end. alice is on the adjusted (unlocked)
    # branch — annexed files stay real, editable files, not symlinks — and her
    # assistant is off, so the transfer is driven explicitly. alice and the
    # gateway have unrelated git histories, so rather than `sync` (a master
    # merge) we send the content with `copy --to` and re-verify the server's
    # stored bytes against the content hash with `fsck --from`, both over SSH.
    ssh = "GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=no'"
    client.succeed("sudo -u alice bash -c 'head -c 131072 /dev/urandom > /home/alice/Annex/snapshot.bin'")
    client.succeed("sudo -u alice env GIT_PAGER=cat git -C /home/alice/Annex annex add snapshot.bin")
    client.succeed("sudo -u alice env GIT_PAGER=cat git -C /home/alice/Annex commit -m 'add snapshot'")
    # Annexed, yet still a real unlocked file in the working tree (not a symlink).
    client.succeed("sudo -u alice test -f /home/alice/Annex/snapshot.bin")
    client.succeed("sudo -u alice bash -c '! test -L /home/alice/Annex/snapshot.bin'")
    # Send the content to the gateway over SSH (git-annex checksum-verifies on store).
    client.succeed(
        f"sudo -u alice timeout 60s env GIT_PAGER=cat {ssh} "
        "git -C /home/alice/Annex annex copy snapshot.bin --to gateway"
    )
    # The location log now records the gateway as holding a copy...
    client.succeed(
        "sudo -u alice env GIT_PAGER=cat git -C /home/alice/Annex annex whereis snapshot.bin | grep -i gateway"
    )
    # ...and an explicit fsck re-reads the gateway's stored bytes over SSH and
    # checks them against the content hash — proving the binary arrived intact.
    client.succeed(
        f"sudo -u alice timeout 60s env GIT_PAGER=cat {ssh} "
        "git -C /home/alice/Annex annex fsck snapshot.bin --from gateway"
    )

    # 10. Verify Auto Sync
    # Create a file on client_full (where assistant is enabled)
    client_full.succeed("sudo -u bob touch /home/bob/Annex/sync-test-file")
    # Wait for it to sync to gateway
    gateway.wait_until_succeeds("test -f /var/lib/git-annex/gateway/sync-test-file")

    # 10b. The backup guarantee (the ~/Pictures use case): real file CONTENT, of
    # different types, must reach the server — not just the git pointer. The
    # gateway wants all content (group backup / wanted standard), so the assistant
    # transfers the bytes. We use a small text file and a 100 KB binary blob, then
    # verify the server's copy is byte-identical (sha256). Both repos are locked,
    # so sha256sum reads through the worktree symlink into .git/annex/objects and
    # only succeeds once the object has actually transferred (content-present gate).
    client_full.succeed("sudo -u bob bash -c 'echo hello-text > /home/bob/Annex/note.txt'")
    client_full.succeed("sudo -u bob bash -c 'head -c 102400 /dev/urandom > /home/bob/Annex/photo.bin'")
    for fname in ["note.txt", "photo.bin"]:
        gateway.wait_until_succeeds(f"sha256sum /var/lib/git-annex/gateway/{fname}", timeout=120)
        client_sha = client_full.succeed(f"sudo -u bob sha256sum /home/bob/Annex/{fname}").split()[0]
        gateway_sha = gateway.succeed(f"sha256sum /var/lib/git-annex/gateway/{fname}").split()[0]
        assert client_sha == gateway_sha, (
            f"{fname}: content differs (client {client_sha} != gateway {gateway_sha})"
        )

    # 11. Verify per-remote cost was applied declaratively.
    client_full.succeed("sudo -u bob git -C /home/bob/Annex config remote.gateway.annex-cost | grep 50")

    # Stop the assistant so the remaining checks are deterministic (it can't race
    # in its own commits or transfers).
    client_full.succeed(
        "sudo -u bob XDG_RUNTIME_DIR=/run/user/1000 systemctl --user stop git-annex-assistant.service"
    )

    # 11b. Preferred-content ("wanted") ROUTING. bob's `backup` directory remote
    # declaratively wants only *.jpg. `copy --auto` honours each remote's
    # preferred content, so the jpg's bytes land on backup while the txt's do not
    # — proving content is routed by the wanted expression, not copied blindly.
    client_full.succeed("sudo -u bob bash -c 'head -c 51200 /dev/urandom > /home/bob/Annex/cat.jpg'")
    client_full.succeed(
        "sudo -u bob env GIT_PAGER=cat git -C /home/bob/Annex annex add cat.jpg note.txt"
    )
    client_full.succeed(
        "sudo -u bob env GIT_PAGER=cat git -C /home/bob/Annex commit -m 'wanted-routing fixtures'"
    )
    client_full.succeed(
        "sudo -u bob env GIT_PAGER=cat git -C /home/bob/Annex annex copy --auto --to backup"
    )
    in_backup = client_full.succeed(
        "sudo -u bob env GIT_PAGER=cat git -C /home/bob/Annex annex find --in backup"
    )
    assert "cat.jpg" in in_backup, f"jpg content should be on backup (wanted=*.jpg): {in_backup!r}"
    assert "note.txt" not in in_backup, f"txt content should NOT be on backup: {in_backup!r}"

    # 12. Verify the module's auto-tag post-commit hook tags files on commit.
    #
    # The git-annex assistant commits via its own internal machinery and does NOT
    # invoke git's post-commit hook, so we exercise the hook with an explicit
    # commit (the assistant is already stopped above). Use a non-empty file so it
    # is annexed (git annex metadata only operates on annexed files).
    client_full.succeed("sudo -u bob bash -c 'echo tagme > /home/bob/Annex/tagme.txt'")
    client_full.succeed(
        "sudo -u bob env GIT_PAGER=cat git -C /home/bob/Annex annex add tagme.txt"
    )
    # The post-commit hook fires here and tags the newly committed file.
    client_full.succeed(
        "sudo -u bob env GIT_PAGER=cat git -C /home/bob/Annex commit -m 'add tagme'"
    )
    client_full.wait_until_succeeds(
        "sudo -u bob env GIT_PAGER=cat git -C /home/bob/Annex annex metadata tagme.txt --get tag | grep hm",
        timeout=60,
    )

    print(
        "SUCCESS: unlock, unlocked binary transfer over SSH (fsck-verified), auto-sync, "
        "content backup (text + binary, integrity-checked), wanted-based routing, "
        "per-remote cost, and auto-tagging all verified."
    )
  '';
}
