# Coverage for init-script behaviours that the other tests don't exercise:
#   - numcopies is enforced globally,
#   - the auto-tag post-commit hook tags annexed files on an explicit commit,
#   - re-running the init oneshot on an already-set-up repo is a clean no-op
#     (guards the "already initialized / already adjusted / remote already
#     added" idempotency branches — including the guarded UUID grep),
#   - a remote whose expectedUUID does not match is rejected loudly (init fails).
{ pkgs, ... }:
let
  helper = import ./lib.nix { inherit pkgs; };
  gatewayUrl = "git-annex@gateway:/var/lib/git-annex/gateway";
in
pkgs.testers.nixosTest {
  name = "git-annex-init-hardening";
  nodes = {
    gateway =
      { ... }:
      {
        imports = [ helper.commonNode ];
        services.git-annex.repositories.gateway = {
          path = "/var/lib/git-annex/gateway";
          description = "gateway";
          group = "backup";
          wanted = "standard";
        };
      };

    # numcopies + tags + idempotency.
    client =
      { ... }:
      {
        imports = [ helper.commonNode ];
        services.git-annex.repositories.client = {
          path = "/var/lib/git-annex/client";
          description = "client";
          numcopies = 2;
          tags = [ "archive" ];
          remotes = [
            {
              name = "origin";
              url = gatewayUrl;
            }
          ];
        };
      };

    # A remote with a deliberately wrong expectedUUID: init must fail loudly.
    client_baduuid =
      { ... }:
      {
        imports = [ helper.commonNode ];
        services.git-annex.repositories.baduuid = {
          path = "/var/lib/git-annex/baduuid";
          description = "baduuid";
          remotes = [
            {
              name = "origin";
              url = gatewayUrl;
              expectedUUID = "00000000-0000-0000-0000-000000000000";
            }
          ];
        };
      };
  };

  testScript = ''
    start_all()
    gateway.wait_for_unit("git-annex-init-gateway.service")
    client.wait_for_unit("git-annex-init-client.service")

    C = "sudo -u git-annex env GIT_PAGER=cat git -C /var/lib/git-annex/client"

    # --- numcopies enforced globally ---
    nc = client.succeed(f"{C} annex numcopies").strip()
    assert "2" in nc, f"numcopies should be 2, got {nc!r}"

    # --- tags: the module writes .git/hooks/post-commit from repo.tags, and it
    # tags annexed files on an explicit `git commit` ---
    client.succeed("test -x /var/lib/git-annex/client/.git/hooks/post-commit")
    client.succeed("sudo -u git-annex bash -c 'echo tagme > /var/lib/git-annex/client/tagme.txt'")
    client.succeed(f"{C} annex add tagme.txt")
    client.succeed(f"{C} commit -m 'add tagme'")
    meta = client.succeed(f"{C} annex metadata tagme.txt")
    assert "archive" in meta, f"tag 'archive' should be applied by the post-commit hook: {meta!r}"

    # --- idempotency: re-running the init oneshot on an already-set-up repo must
    # exit 0 (the restart blocks on ExecStart for a RemainAfterExit oneshot, so a
    # non-zero re-init would fail here) and must not duplicate the remote ---
    client.succeed("systemctl restart git-annex-init-client.service")
    remotes = client.succeed(f"{C} remote").split()
    assert remotes == ["origin"], f"remote should be exactly ['origin'] after re-init, got {remotes!r}"
    # numcopies and the tag hook survive the re-init
    assert "2" in client.succeed(f"{C} annex numcopies")
    client.succeed("test -x /var/lib/git-annex/client/.git/hooks/post-commit")

    # --- expectedUUID mismatch → init FAILS loudly (fetch succeeds, then the
    # UUID check rejects the remote and the script exits non-zero) ---
    client_baduuid.wait_until_fails(
        "systemctl is-active git-annex-init-baduuid.service", timeout=180
    )
    client_baduuid.succeed("systemctl is-failed git-annex-init-baduuid.service")
    client_baduuid.succeed(
        "journalctl -u git-annex-init-baduuid.service --no-pager | grep -i 'UUID mismatch'"
    )
  '';
}
