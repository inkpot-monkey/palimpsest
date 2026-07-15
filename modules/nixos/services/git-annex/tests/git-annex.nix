{ pkgs, ... }:

let
  helper = import ./lib.nix { inherit pkgs; };
in
pkgs.testers.nixosTest {
  name = "git-annex-sync";
  nodes = {
    gateway =
      { ... }:
      {
        imports = [ helper.commonNode ];
        services.git-annex.repositories.gateway = {
          path = "/var/lib/git-annex/gateway";
          description = "gateway";
          gateway = true;
          wanted = "standard";
          group = "transfer";
        };
      };

    client =
      { ... }:
      {
        imports = [ helper.commonNode ];
        services.git-annex.repositories.client = {
          path = "/var/lib/git-annex/client";
          description = "client";
          remotes = [
            {
              name = "origin";
              url = "git-annex@gateway:/var/lib/git-annex/gateway";
            }
          ];
        };
      };
  };

  # SSH trust is established declaratively at boot via the shared key in lib.nix,
  # and the init service retries its fetch until the gateway is reachable, so the
  # init oneshots succeed on first boot with no manual key exchange or restart.
  testScript = ''
    start_all()

    gateway.wait_for_unit("git-annex-init-gateway.service")
    client.wait_for_unit("git-annex-init-client.service")

    # Repo was initialized
    client.succeed("test -d /var/lib/git-annex/client/.git")

    # Create a file on the client and push it to the gateway over SSH
    client.succeed("sudo -u git-annex bash -c 'cd /var/lib/git-annex/client && echo test > test.txt'")
    client.succeed("sudo -u git-annex git -C /var/lib/git-annex/client add .")
    client.succeed("sudo -u git-annex git -C /var/lib/git-annex/client commit -m 'test commit'")
    # --force because each repo self-inits with its own unrelated initial commit;
    # the gateway's receive.denyCurrentBranch=updateInstead updates its worktree.
    client.succeed("sudo -u git-annex git -C /var/lib/git-annex/client push origin master --force")

    # Exercise the annex sync path too (non-fatal: the git push above already
    # delivers the file via updateInstead).
    code, out = client.execute("sudo -u git-annex git -C /var/lib/git-annex/client annex sync 2>&1")
    print(out)

    gateway.wait_for_file("/var/lib/git-annex/gateway/test.txt")
  '';
}
