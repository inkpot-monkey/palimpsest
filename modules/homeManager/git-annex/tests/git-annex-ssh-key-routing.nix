# Regression test for the dedicated-SSH-key routing fix.
#
# The rest of the suite copies the git-annex key to the client's DEFAULT
# ~/.ssh/id_ed25519, so it can never catch a client that authenticates with the
# wrong key. This test does the opposite of what a workstation looks like on
# purpose: the client's default identity is an UNAUTHORIZED key, and the
# dedicated annex key is supplied only through `services.git-annex.sshKeyFile`.
# A successful content transfer therefore proves the key was routed via the
# repo's persisted git config (core.sshCommand + annex.ssh-options) — the fix —
# rather than the default identity the assistant/CLI would otherwise fall back
# to. Also asserts `thin` (unlocked worktree file hardlinked to the object).
{
  pkgs,
  inputs,
}:
let
  # Two independent keypairs: `annex` is authorized on the gateway; `wrong` is
  # the client's default identity and is NOT authorized anywhere.
  keys =
    pkgs.runCommand "git-annex-routing-keys"
      {
        nativeBuildInputs = [ pkgs.openssh ];
      }
      ''
        mkdir -p $out
        ssh-keygen -t ed25519 -N "" -C "annex" -f $out/annex
        ssh-keygen -t ed25519 -N "" -C "wrong" -f $out/wrong
      '';
in
pkgs.testers.nixosTest {
  name = "git-annex-ssh-key-routing";
  nodes = {
    gateway =
      { ... }:
      {
        imports = [ (inputs.self + /modules/nixos/services/git-annex/default.nix) ];
        services.openssh.enable = true;
        networking.firewall.allowedTCPPorts = [ 22 ];
        services.git-annex = {
          enable = true;
          repositories.store = {
            path = "/var/lib/git-annex/store";
            description = "store";
            # Want all content, like kelpy's `pictures` repo.
            group = "backup";
            wanted = "standard";
          };
        };
        # Authorize ONLY the dedicated annex key. The client's default key is a
        # different, unauthorized key, so any successful transfer proves the
        # client used the annex key routed through its repo config.
        users.users.git-annex.openssh.authorizedKeys.keyFiles = [ "${keys}/annex.pub" ];
      };

    client =
      { pkgs, ... }:
      {
        imports = [ inputs.home-manager.nixosModules.home-manager ];

        users.users.carol = {
          isNormalUser = true;
          extraGroups = [ "wheel" ];
        };

        environment.systemPackages = [
          pkgs.git
          pkgs.git-annex
          pkgs.openssh
        ];

        # Install both keys as carol-owned 0600 files at boot (before the user
        # init service runs): the DEFAULT identity is the WRONG (unauthorized)
        # key; the annex key sits beside it and is wired via sshKeyFile below.
        # `install` sets mode+owner atomically; deps=["users"] runs it after the
        # home directory exists.
        system.activationScripts.carolKeys = {
          deps = [ "users" ];
          text = ''
            install -d -m 0700 -o carol -g users /home/carol/.ssh
            install -m 0600 -o carol -g users ${keys}/wrong /home/carol/.ssh/id_ed25519
            install -m 0600 -o carol -g users ${keys}/annex /home/carol/.ssh/annexkey
          '';
        };

        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
        home-manager.users.carol =
          { ... }:
          {
            imports = [ ../default.nix ];
            config = {
              home.stateVersion = "24.05";
              programs.git = {
                enable = true;
                settings.user = {
                  name = "Carol";
                  email = "carol@example.com";
                };
              };
              services.git-annex = {
                enable = true;
                # The dedicated key — NOT carol's default identity.
                sshKeyFile = "/home/carol/.ssh/annexkey";
                repositories.annex = {
                  path = "/home/carol/Annex";
                  description = "carol-annex";
                  unlock = true;
                  thin = true;
                  remotes = [
                    {
                      name = "gateway";
                      url = "git-annex@gateway:/var/lib/git-annex/store";
                    }
                  ];
                };
                # Drive transfers explicitly so the assertion isolates key routing
                # from assistant timing.
                assistant.enable = false;
              };
            };
          };
      };
  };

  testScript = ''
    start_all()
    gateway.wait_for_unit("sshd.service")
    gateway.wait_for_unit("git-annex-init-store.service")

    client.succeed("loginctl enable-linger carol")
    client.wait_for_unit("user@1000.service")

    run = "sudo -u carol XDG_RUNTIME_DIR=/run/user/1000 "

    # The home init oneshot fetches from the gateway using the dedicated annex
    # key (via the init unit's GIT_SSH_COMMAND). Poll active|failed so a failed
    # unit raises immediately with its journal.
    def wait_init():
        for _ in range(120):
            state = client.succeed(
                run + "systemctl --user is-active git-annex-init-annex.service || true"
            ).strip()
            if state == "active":
                return
            if state == "failed":
                client.succeed(run + "journalctl --user -u git-annex-init-annex.service --no-pager >&2 || true")
                raise Exception("git-annex-init-annex failed")
            client.sleep(1)
        client.succeed(run + "journalctl --user -u git-annex-init-annex.service --no-pager >&2 || true")
        raise Exception("git-annex-init-annex never became active")

    wait_init()

    # The fix: the annex key is persisted into the repo git config, so operations
    # that run WITHOUT the init unit's transient env still use it.
    core_ssh = client.succeed("sudo -u carol git -C /home/carol/Annex config core.sshCommand")
    assert "/home/carol/.ssh/annexkey" in core_ssh, f"core.sshCommand missing annex key: {core_ssh!r}"
    ssh_opts = client.succeed("sudo -u carol git -C /home/carol/Annex config annex.ssh-options")
    assert "/home/carol/.ssh/annexkey" in ssh_opts, f"annex.ssh-options missing annex key: {ssh_opts!r}"

    # Negative control: carol's DEFAULT identity is the wrong key, so a plain ssh
    # to the git-annex user must be REJECTED. (If this ever succeeds, the test is
    # not actually exercising the routing — the default key would be enough.)
    client.fail(
        "sudo -u carol ssh -o BatchMode=yes -o StrictHostKeyChecking=no "
        "-o ConnectTimeout=10 git-annex@gateway true"
    )

    # Positive: transfer content with NO GIT_SSH_COMMAND override. This can only
    # succeed if git-annex picks the annex key up from the repo config, not
    # carol's default (wrong) key.
    client.succeed("sudo -u carol bash -c 'head -c 131072 /dev/urandom > /home/carol/Annex/blob.bin'")
    client.succeed("sudo -u carol env GIT_PAGER=cat git -C /home/carol/Annex annex add blob.bin")
    client.succeed("sudo -u carol env GIT_PAGER=cat git -C /home/carol/Annex commit -m 'add blob'")
    client.succeed(
        "sudo -u carol timeout 60s env GIT_PAGER=cat "
        "git -C /home/carol/Annex annex copy blob.bin --to gateway"
    )
    client.succeed(
        "sudo -u carol env GIT_PAGER=cat git -C /home/carol/Annex annex whereis blob.bin | grep -i gateway"
    )

    # Verify the bytes actually reached the gateway. The gateway repo is locked,
    # so `copy --to` transfers the object without materialising a worktree file;
    # `fsck --from` re-reads the gateway's stored object over SSH and checks it
    # against the content hash. Run with NO GIT_SSH_COMMAND, so it too must rely
    # on the persisted repo config — a second proof the annex key carries it.
    client.succeed(
        "sudo -u carol timeout 60s env GIT_PAGER=cat "
        "git -C /home/carol/Annex annex fsck blob.bin --from gateway"
    )

    # thin: the unlocked worktree file is a HARDLINK to the annex object (nlink>1),
    # i.e. stored once locally rather than duplicated.
    client.succeed("sudo -u carol git -C /home/carol/Annex config --bool annex.thin | grep -x true")
    nlink = client.succeed("sudo -u carol stat -c %h /home/carol/Annex/blob.bin").strip()
    assert int(nlink) > 1, f"thin worktree file should be hardlinked (nlink>1), got {nlink}"
  '';
}
