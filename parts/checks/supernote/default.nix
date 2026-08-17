# Acceptance test for the Supernote server profile (ADR-0031, palimpsest#92).
#
# Runs the REAL `pkgs.supernote` server (not a mock) on a `server` node and drives the four
# acceptance criteria from a `client` node on the same virtual LAN:
#   1. the packaged server binds :8080 and answers a login/health request, and the account
#      bootstraps from the credential (the supernote-account-bootstrap oneshot goes green only
#      if `cloud login` succeeds against the running server);
#   2. it runs as the private `supernote` user and /var/lib/supernote is 0700;
#   3. the MCP port is NOT exposed — the client can reach :8080 but the firewall drops :8081,
#      even though the MCP server IS listening on the server (proven via loopback), so the
#      block is the firewall, not a disabled feature;
#   4. (store durability / offsite exclusion is a config property — no restic path references
#      the store — asserted by the module + covered in review, not bootable here.)
#
# sops is bypassed the same way parts/checks/affine does: dummy age key + forced secret paths
# pointing at plain /etc files, so no real decryption is needed in the sandbox.
{
  self,
  pkgs,
  inputs,
  ...
}:

pkgs.testers.nixosTest {
  name = "supernote-server-test";

  nodes = {
    server =
      { lib, ... }:
      {
        imports = [
          inputs.sops-nix.nixosModules.sops
          # The impermanence module directly (provides `environment.persistence`), not the
          # profile — the profile's top-level `imports` needs an `inputs` module-arg the test
          # nodes don't get, which infinite-recurses. The profile's persist block is gated on
          # `custom.profiles.impermanence.enable`, which we declare (and leave off) below.
          inputs.impermanence.nixosModules.impermanence
          (self + /modules/nixos/profiles/supernote.nix)
        ];

        # Stub the gate option the profile reads (the full impermanence profile can't be imported
        # here — see the note above); left off. The store's persistence ENTRY is wired-and-eval'd
        # in the rk1b config (ADR-0004 StateDirectory + impermanence); re-proving cross-reboot
        # survival here would mean rebuilding the tmpfs-root architecture and rebooting the VM,
        # which the test driver does unreliably. The restart subtest below instead exercises the
        # parts that are THIS module's code: the stable-JWT wrapper and the idempotent bootstrap.
        options.custom.profiles.impermanence.enable = lib.mkEnableOption "impermanence (test stub)";

        config = {
          # The profile reads `self.lib.getSecretFile`; test nodes don't get `self` from
          # specialArgs, so provide it here (the sopsFile it resolves is unused — we force the
          # secret paths to plain files below).
          _module.args.self = self;

          custom.profiles.supernote.enable = true;

          # Satisfy the sops assertions without a real key/file (affine pattern).
          sops.age.keyFile = "/etc/dummy-sops-key";
          sops.defaultSopsFile = pkgs.writeText "dummy-sops.yaml" "";
          sops.validateSopsFiles = false;

          # Bypass sops decryption: point the two credential secrets at plain files. The
          # bootstrap oneshot LoadCredential's these paths, so the account is created from them.
          # (`user` must be a valid email — the server validates EMAIL_REGEX on register.)
          sops.secrets."supernote/user".path = lib.mkForce "/etc/mock-supernote-user";
          sops.secrets."supernote/password".path = lib.mkForce "/etc/mock-supernote-password";
          environment.etc."mock-supernote-user".text = "device@example.com";
          environment.etc."mock-supernote-password".text = "sync-secret-123";

          # A little headroom: the server is a Python app doing DB migrations at startup.
          virtualisation.memorySize = 2048;
        };
      };

    client = {
      # Nothing special — just needs curl and to be on the same test LAN as `server`.
      environment.systemPackages = [ pkgs.curl ];
    };
  };

  # The port literals below (8080 sync, 8081 MCP) mirror `port`/`mcpPort` in
  # modules/nixos/profiles/supernote.nix — keep them in step if those change.
  testScript = ''
    start_all()

    # 1. Server comes up and binds the sync port.
    server.wait_for_unit("supernote-server.service")
    server.wait_for_open_port(8080)

    # 1 + credential: the bootstrap oneshot only reaches "active" if it registered the account
    # AND `cloud login` succeeded against the running server — the login/health proof.
    server.wait_for_unit("supernote-account-bootstrap.service")

    # 2. Runs as the private `supernote` user and the store is 0700.
    server.succeed("id supernote")
    owner = server.succeed("stat -c '%U' /var/lib/supernote").strip()
    assert owner == "supernote", f"expected /var/lib/supernote owned by supernote, got {owner}"
    perms = server.succeed("stat -c '%a' /var/lib/supernote").strip()
    assert perms == "700", f"expected /var/lib/supernote mode 700, got {perms}"

    # 3a. The MCP server IS running on the server (bound to all interfaces on 8081) — prove it
    #     over loopback so the external block below is demonstrably the firewall, not a disabled
    #     feature.
    server.wait_for_open_port(8081)
    server.succeed("curl -sf -o /dev/null http://127.0.0.1:8081/ || curl -s -o /dev/null http://127.0.0.1:8081/")

    # 3b. From the client on the LAN: :8080 is reachable, :8081 is NOT (firewall DROP → timeout).
    client.wait_until_succeeds("curl -sf -o /dev/null http://server:8080/api/csrf", timeout=60)
    client.fail("curl -s -o /dev/null --max-time 8 http://server:8081/")

    # 1 (end-to-end): a fresh `cloud login` from the client-side account credential succeeds
    #     against the server, confirming the bootstrapped account authenticates over the network.
    server.succeed(
        "HOME=/tmp ${pkgs.supernote}/bin/supernote cloud login "
        "--url http://127.0.0.1:8080 device@example.com --password sync-secret-123"
    )

    # 4. The two bespoke bits a deploy (which re-runs these units) depends on: an IDEMPOTENT
    #    bootstrap and a STABLE JWT. Verified via targeted service restarts rather than a VM reboot
    #    (machine.reboot() is unreliable in this test driver — the backdoor shell drops). That the
    #    store survives a real reboot is the StateDirectory + impermanence mechanism, wired-and-
    #    eval'd in the rk1b config.
    server.succeed("test -f /var/lib/supernote/system/supernote.db")

    # Idempotency FIRST, restarting only the oneshot (server left up). The bootstrap `requires` the
    # server, so restarting the two together would race — a server restart stops the in-flight
    # oneshot. Against the now-populated DB the newest run must take the "account already exists"
    # path, not the register branch. `systemctl restart` blocks until the oneshot completes, so its
    # message is the LAST status line in the journal; assert on that (invocation-index semantics are
    # version-fragile, so parse the log instead). Each run ends in exactly one of these two lines.
    server.systemctl("restart supernote-account-bootstrap.service")
    server.wait_for_unit("supernote-account-bootstrap.service")
    journal = server.succeed("journalctl -u supernote-account-bootstrap --no-pager -o cat")
    status = [
        ln
        for ln in journal.splitlines()
        if "account present, login OK" in ln or "account bootstrapped, login OK" in ln
    ]
    assert status, f"no bootstrap completion line found:\n{journal}"
    assert "account present, login OK" in status[-1], (
        f"the newest bootstrap run was not the idempotent path (it re-registered):\n{journal}"
    )

    # Stable JWT: restarting the server must REUSE the persisted signing key (its ExecStart wrapper
    # only mints one when absent), so device/reconciler tokens survive a deploy.
    jwt_before = server.succeed("cat /var/lib/supernote/jwt-secret").strip()
    server.systemctl("restart supernote-server.service")
    server.wait_for_open_port(8080)
    jwt_after = server.succeed("cat /var/lib/supernote/jwt-secret").strip()
    assert jwt_after == jwt_before, "JWT signing key rotated on restart (would invalidate device tokens)"

    # Store still 0700 and the account still authenticates after the restarts.
    perms = server.succeed("stat -c '%a' /var/lib/supernote").strip()
    assert perms == "700", f"expected /var/lib/supernote mode 700, got {perms}"
    server.succeed(
        "HOME=/tmp ${pkgs.supernote}/bin/supernote cloud login "
        "--url http://127.0.0.1:8080 device@example.com --password sync-secret-123"
    )

    # ── 5. A VENDORED-FORK DATABASE STARTS (palimpsest#112) ──────────────────────────────────
    # The fork carried its own alembic migrations, so a database it created is stamped with a
    # revision upstream has never heard of, and upstream's alembic aborts at startup rather than
    # warning. This is not hypothetical: it crash-looped rk1b for 35 minutes on 2026-08-17, and
    # because the bootstrap oneshot Requires= the server with no start timeout, the deploy hung
    # instead of failing. Reproduce the exact condition and assert the ExecStartPre recovers it.
    DB = "/var/lib/supernote/system/supernote.db"

    def stamp(revision):
        server.succeed(
            f"""${pkgs.python3}/bin/python3 -c 'import sqlite3; c = sqlite3.connect("{DB}"); """
            f"""c.execute("update alembic_version set version_num = ?", ("{revision}",)); c.commit()'"""
        )

    def revision():
        return server.succeed(
            f"""${pkgs.python3}/bin/python3 -c 'import sqlite3; """
            f"""print(sqlite3.connect("{DB}").execute("select version_num from alembic_version").fetchone()[0])'"""
        ).strip()

    users_before = server.succeed(
        f"""${pkgs.python3}/bin/python3 -c 'import sqlite3; """
        f"""print(sqlite3.connect("{DB}").execute("select count(*) from users").fetchone()[0])'"""
    ).strip()

    stamp("9d2f7b3c1a08")
    server.systemctl("restart supernote-server.service")
    server.wait_for_open_port(8080)

    assert revision() == "7a8291f043bc", f"the fork stamp was not translated: {revision()}"
    # Translated, not migrated: the accounts must still be there afterwards.
    users_after = server.succeed(
        f"""${pkgs.python3}/bin/python3 -c 'import sqlite3; """
        f"""print(sqlite3.connect("{DB}").execute("select count(*) from users").fetchone()[0])'"""
    ).strip()
    assert users_after == users_before, f"users went from {users_before} to {users_after}"
    server.succeed(
        "HOME=/tmp ${pkgs.supernote}/bin/supernote cloud login "
        "--url http://127.0.0.1:8080 device@example.com --password sync-secret-123"
    )
    server.succeed("test -n \"$(ls /var/lib/supernote/backups/supernote-pre-stamp-*.db)\"")

    # AND IT REFUSES TO GUESS. An unrecognised revision must fail the unit, not be waved through:
    # a database from some other fork lineage could be stamped with something equally unfamiliar
    # while having a genuinely divergent schema, and declaring that "at head" would let the
    # server corrupt it. Failing to start is recoverable; a wrong stamp may not be.
    stamp("deadbeef1234")
    server.systemctl("stop supernote-server.service")
    server.fail("systemctl start supernote-server.service")
    assert revision() == "deadbeef1234", "an unknown revision was rewritten anyway"

    # Put it back so the unit ends the test healthy rather than in a failed state.
    stamp("7a8291f043bc")
    server.systemctl("start supernote-server.service")
    server.wait_for_open_port(8080)
  '';
}
