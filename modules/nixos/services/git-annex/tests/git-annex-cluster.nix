{ pkgs, ... }:

# Declarative cluster + proxy test.
#
# The gateway is configured as a cluster gateway that proxies the `backup` node.
# A client then stores content into the cluster and later retrieves it back from
# the cluster — content it no longer holds locally is fetched from `backup`
# *through* the gateway proxy. Everything (annex-proxy, annex-cluster-node,
# trust, updateproxy/updatecluster) is set declaratively by the module; the test
# does ZERO manual git-annex proxy/cluster/uuid configuration. This replaces the
# old git-annex-stateless.nix debugging scratchpad (spoof shells, strace, manual
# annex-proxy/cost/trust).
let
  helper = import ./lib.nix { inherit pkgs; };
in
pkgs.testers.nixosTest {
  name = "git-annex-cluster";
  nodes = {
    gateway =
      { ... }:
      {
        imports = [ helper.commonNode ];
        services.git-annex.repositories.gateway = {
          path = "/var/lib/git-annex/gateway";
          description = "gateway";
          gateway = true;
          clusterName = "mycluster";
          # The gateway is a passthrough proxy: it keeps no content of its own.
          wanted = "nothing";
          remotes = [
            {
              name = "backup";
              url = "git-annex@backup:/var/lib/git-annex/backup";
              clusterNode = "mycluster";
              proxy = true;
              trust = "trusted";
            }
          ];
        };
      };

    backup =
      { ... }:
      {
        imports = [ helper.commonNode ];
        services.git-annex.repositories.backup = {
          path = "/var/lib/git-annex/backup";
          description = "backup";
          group = "backup";
          wanted = "standard";
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

  testScript = ''
    start_all()

    # All init oneshots succeed on first boot (shared SSH key + fetch retry).
    gateway.wait_for_unit("git-annex-init-gateway.service")
    backup.wait_for_unit("git-annex-init-backup.service")
    client.wait_for_unit("git-annex-init-client.service")

    # GIT_PAGER=cat: the VM console reads as a tty, so `git show` would otherwise
    # invoke a pager and hang waiting for input.
    def annex(node, repo, args):
        return node.succeed(f"sudo -u git-annex env GIT_PAGER=cat git -C /var/lib/git-annex/{repo} annex {args}")

    def git(node, repo, args):
        return node.succeed(f"sudo -u git-annex env GIT_PAGER=cat git -C /var/lib/git-annex/{repo} {args}")

    # 1. The gateway published cluster + proxy config to its git-annex branch.
    backup_uuid = backup.succeed("sudo -u git-annex git -C /var/lib/git-annex/backup config annex.uuid").strip()
    git(gateway, "gateway", "show git-annex:cluster.log >&2")
    git(gateway, "gateway", "show git-annex:proxy.log >&2")
    git(gateway, "gateway", f"show git-annex:cluster.log | grep {backup_uuid}")

    # 2. Client creates an annexed file.
    client.succeed("sudo -u git-annex bash -c 'cd /var/lib/git-annex/client && echo cluster_test > test.txt'")
    annex(client, "client", "add test.txt")
    git(client, "client", "commit -m 'cluster test'")

    # 3. Client learns the cluster by fetching the gateway's git-annex branch.
    #    `annex merge` union-merges the git-annex branch (carrying cluster.log /
    #    proxy.log) without touching master, so the repos' unrelated master
    #    histories don't matter. After this the proxied cluster remote
    #    `origin-mycluster` is available.
    git(client, "client", "fetch origin")
    annex(client, "client", "merge")

    git(client, "client", "remote -v >&2")
    annex(client, "client", "info >&2")

    # 4. Client stores content INTO the cluster. The gateway proxies the upload to
    #    the backup node.
    annex(client, "client", "copy test.txt --to origin-mycluster")

    # 5. Placement: content landed on backup; the proxy gateway kept none.
    backup.succeed("find /var/lib/git-annex/backup/.git/annex/objects -type f | grep .")
    gateway.succeed("! find /var/lib/git-annex/gateway/.git/annex/objects -type f | grep .")

    # 6. Client drops its local copy (the cluster still has it on backup).
    annex(client, "client", "drop test.txt")
    client.succeed("! test -s /var/lib/git-annex/client/test.txt")

    # 7. HEADLINE: client retrieves the content again FROM THE CLUSTER. It is
    #    served from backup THROUGH the gateway proxy, with no manual config.
    annex(client, "client", "get test.txt --from origin-mycluster")
    client.succeed("grep cluster_test /var/lib/git-annex/client/test.txt")

    print("SUCCESS: content retrieved from backup through the gateway proxy.")
  '';
}
