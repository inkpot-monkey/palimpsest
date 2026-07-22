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

    # A repo running the assistant, to pin the init/assistant interaction. Kept on its
    # own node so the assistant's background commits can't perturb the numcopies/tag
    # assertions on `client`.
    client_assistant =
      { ... }:
      {
        imports = [ helper.commonNode ];
        services.git-annex.repositories.assist = {
          path = "/var/lib/git-annex/assist";
          description = "assist";
          assistant = true;
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

    # --- a CHANGED `url` must reach an already-initialized repo. `git remote add` is
    # a no-op once the remote exists, so without an explicit set-url the repo keeps the
    # original URL forever and an edited `url` in Nix silently does nothing — the only
    # symptom being git-annex failing to connect while history still looks healthy.
    # Simulate the drift by pointing the remote elsewhere, then re-init. ---
    client.succeed(f"{C} remote set-url origin ssh://stale.invalid/gone")
    client.succeed("systemctl restart git-annex-init-client.service")
    url = client.succeed(f"{C} remote get-url origin").strip()
    assert url == "${gatewayUrl}", f"init must reconcile a drifted remote URL back to the declared one, got {url!r}"
    # and it still must not have duplicated the remote while doing so
    assert client.succeed(f"{C} remote").split() == ["origin"]

    # --- re-running init must leave the assistant RUNNING. init's ExecStartPre stops
    # the assistant to avoid racing it, so without an ExecStartPost putting it back,
    # every deploy that re-runs init (any repo config change) left the assistant dead
    # until the next reboot — the repo silently stops noticing and syncing new files
    # while every unit still reports healthy. This is the actual deploy path. ---
    client_assistant.wait_for_unit("git-annex-init-assist.service")
    client_assistant.wait_for_unit("git-annex-assistant-assist.service")
    client_assistant.succeed("systemctl restart git-annex-init-assist.service")
    client_assistant.wait_for_unit("git-annex-assistant-assist.service", timeout=90)
    client_assistant.succeed("systemctl is-active --quiet git-annex-assistant-assist.service")

    # --- the assistant must be RESTARTED when its process dies, not left dead. In
    # production it died on SIGPIPE (broken sync connection) and stayed down: Type=forking
    # made systemd see the signal-death as a clean exit, so Restart=on-failure never fired
    # and the repo silently stopped replicating. Kill the daemon and prove systemd brings
    # it back (Type=simple + --foreground + Restart=always). ---
    old_pid = client_assistant.succeed(
        "systemctl show -p MainPID --value git-annex-assistant-assist.service"
    ).strip()
    assert old_pid not in ("", "0"), f"expected a live assistant MainPID, got {old_pid!r}"
    client_assistant.succeed(f"kill -KILL {old_pid}")
    client_assistant.wait_until_succeeds(
        "systemctl is-active --quiet git-annex-assistant-assist.service", timeout=120
    )
    new_pid = client_assistant.succeed(
        "systemctl show -p MainPID --value git-annex-assistant-assist.service"
    ).strip()
    assert new_pid not in ("", "0") and new_pid != old_pid, (
        f"assistant must be auto-restarted after it dies: old={old_pid!r} new={new_pid!r}"
    )

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
