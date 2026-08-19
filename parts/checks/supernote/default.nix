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
# It also drives palimpsest#143 — a server that cannot start must FAIL the deploy rather than stall
# it — on a second `broken` node that is this same profile with one difference: a server binary
# that exits non-zero at startup. Before #143 that combination (`Requires=supernote-server` plus
# `TimeoutStartUSec=infinity`) produced a silent 35-minute hang with nothing to read; the assertions
# at the end of the script pin the bounded failure, its Result, and the fact that it carries the
# SERVER's own error. Its twin — the server is up and the CREDENTIAL is wrong — is planted on the
# healthy node, because the two failures must not read alike.
#
# sops is bypassed the same way parts/checks/affine does: dummy age key + forced secret paths
# pointing at plain /etc files, so no real decryption is needed in the sandbox.
{
  self,
  pkgs,
  inputs,
  ...
}:
let
  # The bootstrap's own readiness gate and systemd backstop, mirroring `bootstrapReadySec` /
  # `bootstrapTimeoutSec` in modules/nixos/profiles/supernote.nix — keep them in step if those
  # change (same arrangement as the port literals further down). Subtest 5 needs the actual
  # numbers, not just "finite": what makes the failure diagnosable is that the GATE fires and
  # explains itself, and only a bound that sits between the two can tell that apart from the
  # systemd backstop firing over the top of it.
  readySec = 60;
  timeoutSec = 120;

  # The Supernote profile wired for the sandbox. Shared by BOTH server nodes so the broken one
  # below differs in exactly one thing — a server binary that will not start — and its bounded
  # failure can't be an artefact of some other divergence in how it is configured.
  supernoteNode =
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
in

pkgs.testers.nixosTest {
  name = "supernote-server-test";

  nodes = {
    server = supernoteNode;

    # palimpsest#143: a server that cannot start. Planted the way #112's did it — the process exits
    # non-zero at startup with its own error on stderr — because the defect under test is not the
    # alembic stamp (that is fixed) but the class: ANY reason the server won't come up used to hang
    # the deploy unboundedly and silently. What this prints matters as much as that it fails: the
    # bootstrap is supposed to surface the server's error, and the test greps for this exact line,
    # so a bootstrap that merely reported "timed out" would not pass.
    broken =
      { lib, ... }:
      {
        imports = [ supernoteNode ];
        systemd.services.supernote-server.serviceConfig.ExecStart = lib.mkForce (
          pkgs.writeShellScript "supernote-server-unstartable" ''
            echo "alembic.util.exc.CommandError: Can't locate revision identified by 'f0rkrev1'" >&2
            exit 1
          ''
        );
      };

    client = {
      # Nothing special — just needs curl and to be on the same test LAN as `server`.
      environment.systemPackages = [ pkgs.curl ];
    };
  };

  # The port literals below (8080 sync, 8081 MCP) mirror `port`/`mcpPort` in
  # modules/nixos/profiles/supernote.nix — keep them in step if those change.
  testScript = ''
    import time


    def cloud_login(what):
        """A `cloud login` that tolerates upstream gap palimpsest#142.

        Upstream stores ONE login challenge per account (`challenge:{account}`), so two logins for
        the same account that interleave clobber each other and the loser gets a misleading 401
        "Invalid credentials". This test shares its single account with the bootstrap oneshot and
        logs in immediately after it, which is precisely the collision #142 describes — and it is
        NOT what any of these subtests is asserting. They assert that the account authenticates;
        winning a race against a concurrent login is a different claim, and one production does not
        make either (the mirror retries for exactly this reason, and rk1b logs in first try).

        Retrying keeps the assertion honest rather than weakening it: a genuinely bad credential
        401s on every attempt and still fails here, just a few seconds later. Kept small because
        every attempt, failures included, counts against upstream's per-account rate limit of 10
        per 60s — checked BEFORE credentials are verified — so a long retry loop would trade a
        rare race for a reliable 429.
        """
        for attempt in range(1, 4):
            status = server.execute(
                "HOME=/tmp ${pkgs.supernote}/bin/supernote cloud login "
                "--url http://127.0.0.1:8080 device@example.com --password sync-secret-123"
            )[0]
            if status == 0:
                return
            print(f"{what}: login attempt {attempt}/3 failed — probably palimpsest#142, retrying")
            time.sleep(3)
        raise Exception(f"{what}: `cloud login` failed three times — not a lost challenge")


    def assert_verdict(journal, expected, forbidden, what):
        """Both failures must name themselves, and neither may wear the other's name.

        The distinction IS the deliverable (palimpsest#143) — one verdict sends the operator to
        `journalctl -u supernote-server`, the other to the sops bundle — so every check of it is a
        matched pair, and asserting only the positive half would pass a bootstrap that printed
        both.
        """
        assert expected in journal, f"{what}: no {expected!r} verdict:\n{journal}"
        assert forbidden not in journal, f"{what}: it reported {forbidden!r} instead:\n{journal}"


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
    cloud_login("network login")

    # 4. The two bespoke bits a deploy (which re-runs these units) depends on: an IDEMPOTENT
    #    bootstrap and a STABLE JWT. Verified via targeted service restarts rather than a VM reboot
    #    (machine.reboot() is unreliable in this test driver — the backdoor shell drops). That the
    #    store survives a real reboot is the StateDirectory + impermanence mechanism, wired-and-
    #    eval'd in the rk1b config.
    server.succeed("test -f /var/lib/supernote/system/supernote.db")

    # Idempotency FIRST, restarting only the oneshot (server left up) — the DB must be populated
    # for the idempotent path to be the one under test. (A server restart no longer tears this
    # oneshot down mid-run: since palimpsest#143 it only `Wants=` the server, precisely so that it
    # lives long enough to report its own verdict.) Against the now-populated DB the newest run
    # must take the "account already exists" path, not the register branch. `systemctl restart`
    # blocks until the oneshot completes, so its message is the LAST status line in the journal;
    # assert on that (invocation-index semantics are version-fragile, so parse the log instead).
    # Each run ends in exactly one of these two lines.
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
    cloud_login("post-restart login")

    # ── 5. A SERVER THAT CANNOT START FAILS THE DEPLOY, BOUNDED (palimpsest#143) ─────────────
    # The `broken` node has been sitting here since start_all() with a server binary that exits
    # non-zero, so its bootstrap has had the whole test above in which to reach a verdict. Before
    # #143 there was no verdict to reach: `Requires=supernote-server` had systemd SIGTERM the
    # oneshot on every server restart and `TimeoutStartUSec=infinity` meant it could never end, so
    # `nixos-rebuild switch` waited on it for 35 minutes with nothing printed to explain why.

    # (a) The backstop is finite. Asserted directly, because it is what makes an unbounded hang
    #     impossible for ANY reason — including reasons this test cannot plant.
    bound = broken.succeed(
        "systemctl show -p TimeoutStartUSec --value supernote-account-bootstrap.service"
    ).strip()
    assert bound != "infinity", "the bootstrap has no start timeout — it can still hang a deploy (#143)"

    # (b) It reaches `failed`, which is what fails the deploy. The wait is capped just above the
    #     systemd backstop: anything slower than that is already the regression under test.
    broken.wait_until_succeeds(
        "systemctl is-failed --quiet supernote-account-bootstrap.service", timeout=${toString (timeoutSec + 60)}
    )

    #     And it took the time the DESIGN says, not merely some finite time: systemd records the
    #     ExecStart's own start/exit, so the run can be measured rather than inferred from how long
    #     the driver was willing to wait. Landing between the gate and the backstop is the whole
    #     claim — below ${toString readySec}s the gate did not really wait for the server, above
    #     ${toString timeoutSec}s the backstop killed it and the operator gets a bare "timed out"
    #     instead of the diagnosis.
    ran = (
        int(broken.succeed(
            "systemctl show -p ExecMainExitTimestampMonotonic --value supernote-account-bootstrap.service"
        ))
        - int(broken.succeed(
            "systemctl show -p ExecMainStartTimestampMonotonic --value supernote-account-bootstrap.service"
        ))
    ) / 1e6
    assert ${toString readySec} <= ran < ${toString timeoutSec}, (
        f"the bootstrap ran for {ran:.1f}s — outside its own gate (${toString readySec}s) "
        f"and backstop (${toString timeoutSec}s), so the bound under test is not the one in the module"
    )

    # (c) It failed by REPORTING, not by being killed. `exit-code` is the tell that the unit ran its
    #     own gate to completion and exited on its own judgement: under the old `Requires=` it was
    #     torn down by its dependency instead, and a `timeout` result would mean the systemd
    #     backstop fired before the gate that can explain itself.
    result = broken.succeed(
        "systemctl show -p Result --value supernote-account-bootstrap.service"
    ).strip()
    assert result == "exit-code", (
        f"the bootstrap did not fail on its own terms (Result={result}) — it was torn down or timed out"
    )

    # (d) And the failure names the right culprit — the server, not the credential — and carries the
    #     SERVER's own error, which is the one thing the operator actually needs and the one thing
    #     the silent stall never gave them.
    failure = broken.succeed("journalctl -u supernote-account-bootstrap --no-pager -o cat")
    assert_verdict(
        failure, "THE SERVER NEVER CAME UP", "THE CREDENTIAL WAS REJECTED", "an unstartable server"
    )
    assert "Can't locate revision identified by" in failure, (
        f"the server's own startup error was not surfaced in the bootstrap's failure:\n{failure}"
    )

    # ── 6. THE OTHER FAILURE: THE SERVER IS UP AND THE CREDENTIAL IS WRONG (palimpsest#143) ──
    # The two must not read alike — one sends the operator to `journalctl -u supernote-server`, the
    # other to the sops bundle — so the distinction is only worth anything if BOTH sides are pinned.
    # Planted the one way it actually occurs: the store already holds the account (it does, from
    # every subtest above) and the secret no longer matches it. A runtime drop-in swaps the password
    # credential and changes nothing else. Deliberately last, because it leaves the unit failed.
    server.succeed("curl -sf -o /dev/null http://127.0.0.1:8080/api/csrf")
    server.succeed("printf 'not-the-password' > /run/mock-supernote-wrong-password")
    server.succeed("mkdir -p /run/systemd/system/supernote-account-bootstrap.service.d")
    server.succeed(
        "printf '[Service]\\nLoadCredential=\\n"
        "LoadCredential=user:/etc/mock-supernote-user\\n"
        "LoadCredential=password:/run/mock-supernote-wrong-password\\n'"
        " > /run/systemd/system/supernote-account-bootstrap.service.d/wrong-credential.conf"
    )
    server.succeed("systemctl daemon-reload")
    server.fail("systemctl restart supernote-account-bootstrap.service")

    # Read exactly THIS run (invocation-scoped), not the whole unit history — every earlier run in
    # this test succeeded and would otherwise drown the lines under assertion.
    invocation = server.succeed(
        "systemctl show -p InvocationID --value supernote-account-bootstrap.service"
    ).strip()
    failure = server.succeed(f"journalctl _SYSTEMD_INVOCATION_ID={invocation} --no-pager -o cat")
    assert_verdict(
        failure, "THE CREDENTIAL WAS REJECTED", "THE SERVER NEVER CAME UP", "a mismatched credential"
    )
    # It also tells the operator to re-run before rewriting sops. That sentence is not decoration:
    # this is the branch a transient palimpsest#142 lost-login-challenge lands in, wearing exactly
    # the same 401 as a genuinely stale secret, so a verdict without it sends them to fix a file
    # that was never wrong.
    assert "palimpsest#142" in failure, (
        f"the credential verdict does not mention the race that can fake it:\n{failure}"
    )
  '';
}
