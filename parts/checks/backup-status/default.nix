{
  self,
  pkgs,
  inputs,
  ...
}:

# Off-site restic backups (modules/nixos/profiles/backup.nix) — the destination × job cross
# product, the metrics the Backups board draws from, and the two ways retention can quietly
# destroy the wrong snapshots.
#
# Three nodes, because the load-bearing behaviours live in different states:
#
#   off   a host that OWNS an off-site job with everything switched off. The board must show
#         "off", not "no data": a disabled job and a dead exporter must not look alike.
#   on    enabled against an UNREACHABLE repository. This is where the failure paths are: a
#         check that cannot talk to the repository must still publish check_success = 0, and
#         `forget`/`prune` must not be welded into the backup unit.
#   two   enabled against a REAL repository on local disk, with a second destination declared
#         and switched off. Everything that needs restic to actually run lives here —
#         crucially, that retention deletes this host's own snapshots of this job and NOTHING
#         ELSE. The whole fleet shares one repository, so an unscoped `forget` would apply one
#         host's keep-policy to every other host's history; `restic help forget` is explicit
#         that with no filter "all snapshots are first divided into groups" and the policy
#         applied to each. A local-disk destination is only expressible because destinations
#         are data — that is the refactor paying for its own test.

let
  metricsDir = "/var/lib/prometheus-node-exporter-text-files";
  backupModule = self + /modules/nixos/profiles/backup.nix;
  localRepo = "/var/lib/restic-local";
  secondaryRepo = "/var/lib/restic-secondary";

  # 2048M rather than the 1024M default on the two nodes that run restic. This suite grew from
  # two nodes to three with the destinations refactor, and under `nix flake check` — where it
  # competes with every other VM test on the machine — the `on` node died mid-script with a
  # BrokenPipeError on a bare `systemctl is-enabled`, i.e. the VM went away rather than any
  # assertion failing. It passes standalone either way, which is exactly the shape of a test
  # that is fine until CI is busy. restic peaked at 493M RSS on the real host, so 1G for a
  # node running it plus systemd plus the harness was never comfortable.
  resticNodeResources = {
    virtualisation.memorySize = 2048;
  };

  # Satisfy the sops assertions without a real key or file, and bypass decryption by pointing
  # the restic secrets at plain /etc files — the same pattern parts/checks/supernote and
  # parts/checks/affine use. Nothing here decrypts.
  mockSops =
    { lib, ... }:
    {
      sops.age.keyFile = "/etc/dummy-sops-key";
      sops.defaultSopsFile = pkgs.writeText "dummy-sops.yaml" "";
      sops.validateSopsFiles = false;
      sops.secrets.restic_password.path = lib.mkForce "/etc/mock-restic-password";
      sops.secrets.restic_repo.path = lib.mkForce "/etc/mock-restic-repo";
      sops.secrets.restic_ssh_private.path = lib.mkForce "/etc/mock-restic-ssh";
      sops.templates."restic-repo".path = lib.mkForce "/etc/mock-restic-repo-rendered";
      environment.etc."mock-restic-password".text = "not-a-real-password";
      environment.etc."mock-restic-repo".text = "sftp:nowhere:/repo";
      environment.etc."mock-restic-ssh".text = "";
      environment.etc."mock-restic-repo-rendered".text = "sftp:nowhere:/repo";
    };
in
pkgs.testers.nixosTest {
  name = "backup-restic-status";

  nodes.off =
    { ... }:
    {
      imports = [
        backupModule
        # backup.nix references config.sops.* in its (disabled here) enabled paths, so the
        # option namespace must exist even though no secret is defined.
        inputs.sops-nix.nixosModules.sops
      ];
      # backup.nix takes `self` (for getSecretFile, only forced in the enabled paths).
      _module.args.self = self;

      custom.profiles.backup = {
        enable = false;
        monitoringTelemetry.enable = false;
        reportJobs = [
          "daily"
          "telemetry"
        ];
      };

      # Stand up the textfile dir the exporter would own (no monitoring profile here).
      systemd.tmpfiles.rules = [ "d ${metricsDir} 0755 root root -" ];
    };

  nodes.on =
    { ... }:
    {
      imports = [
        backupModule
        inputs.sops-nix.nixosModules.sops
        mockSops
        resticNodeResources
      ];
      _module.args.self = self;

      # ENABLED, so the out-of-band forget, prune and check units exist. There is no reachable
      # repository in the VM and that is the point for `check`: its failure path is what must
      # still publish a metric.
      custom.profiles.backup = {
        enable = true;
        reportJobs = [ "daily" ];
        jobs.daily.paths = [ "/etc/hostname" ];
        # Maintenance is opt-in, so the prune and check units whose failure paths this node
        # exists to exercise only exist if it elects itself.
        destinations.rsyncnet.maintenance = true;
      };

      systemd.tmpfiles.rules = [ "d ${metricsDir} 0755 root root -" ];
    };

  nodes.two =
    { ... }:
    {
      imports = [
        backupModule
        inputs.sops-nix.nixosModules.sops
        mockSops
        resticNodeResources
      ];
      _module.args.self = self;

      custom.profiles.backup = {
        enable = true;
        reportJobs = [ "daily" ];
        jobs.daily = {
          paths = [ "/srv/data" ];
          # Destructive on purpose: with the fleet's real policy nothing is old enough to be
          # deleted in a test, and a `forget` that deletes nothing cannot demonstrate that it
          # deletes the RIGHT things.
          retention = [ "--keep-last 1" ];
        };

        # rsync.net is declared by the profile and switched off here — a VM has no route to
        # it. It must still be REPORTED (enabled = 0), and it must grow no units.
        destinations.rsyncnet.enable = false;

        destinations.local = {
          repository = localRepo;
          passwordFile = "/etc/restic-local-password";
          # The one host elected to maintain this repository.
          maintenance = true;
          # The profile asserts that a job does not fire at the same minute on two
          # destinations; this is the offset that assertion demands.
          settings.timerConfig = {
            OnCalendar = "05:00";
            Persistent = true;
          };
        };

        # A SECOND enabled destination — the shape phase 2 actually adds — left at
        # `maintenance = false`, which is what every host but the elected one must look like.
        # It must receive the backup and run its own retention, and must NOT grow prune or
        # check units.
        destinations.secondary = {
          repository = secondaryRepo;
          passwordFile = "/etc/restic-local-password";
          settings.timerConfig = {
            OnCalendar = "06:00";
            Persistent = true;
          };
        };
      };

      environment.etc."restic-local-password".text = "test-repo-password";
      environment.systemPackages = [ pkgs.restic ];
      systemd.tmpfiles.rules = [
        "d ${metricsDir} 0755 root root -"
        "d /srv/data 0755 root root -"
      ];
    };

  testScript = ''
    import json

    off.wait_for_unit("multi-user.target")

    # Drive the oneshot directly (the timer only fixes *when*).
    off.succeed("systemctl start backup-restic-status.service")
    m = off.succeed("cat ${metricsDir}/backup-restic-status.prom")

    # Both owned jobs surface as known-disabled edges, not as missing data — once per declared
    # destination, so "we turned it off" never looks like "the exporter died". The label is
    # `restic_job`, not the reserved `job` (which the scrape would overwrite to "node").
    assert 'backup_restic_enabled{restic_job="daily",restic_dest="rsyncnet"} 0' in m, m
    assert 'backup_restic_enabled{restic_job="telemetry",restic_dest="rsyncnet"} 0' in m, m
    # A heartbeat so a dead emitter is distinguishable from a healthy all-off host.
    assert "backup_restic_check_timestamp_seconds" in m, m

    # World-readable, or node-exporter (a different user) could never scrape it.
    mode = off.succeed("stat -c %a ${metricsDir}/backup-restic-status.prom").strip()
    assert mode == "644", f"status metrics must be world-readable, got {mode}"

    # A host that backs up nowhere must not be handed another host's repository maintenance.
    off.fail("systemctl cat restic-prune-rsyncnet.service")
    off.fail("systemctl cat restic-check-rsyncnet.service")

    # ---- the ENABLED host: the failure paths ----
    on.wait_for_unit("multi-user.target")

    # The load-bearing property. `forget --prune` must NOT be in the backup unit's ExecStart:
    # ExecStartPost is where last-success is stamped, and it fires only when every ExecStart
    # step succeeded — so a prune failing on a contended lock would suppress the stamp for a
    # backup that actually succeeded, and the Backups board would go cold on a good night.
    backup_unit = on.succeed("systemctl cat restic-backups-daily-rsyncnet.service")
    assert "forget" not in backup_unit, f"forget is welded back into the backup unit:\n{backup_unit}"
    assert "--prune" not in backup_unit, f"prune is welded back into the backup unit:\n{backup_unit}"
    # Every snapshot is tagged with its job, which is what makes retention scopable at all.
    assert "--tag daily" in backup_unit, backup_unit

    # Retention lives in its own unit, scoped to THIS host and THIS job, with the policy
    # intact — and without --prune, which is repository-wide work for one host only.
    forget_unit = on.succeed("systemctl cat restic-forget-daily-rsyncnet.service")
    assert "forget" in forget_unit, forget_unit
    assert "--host on" in forget_unit, f"retention not scoped to this host:\n{forget_unit}"
    assert "--tag daily" in forget_unit, f"retention not scoped to this job:\n{forget_unit}"
    assert "--prune" not in forget_unit, f"retention must not prune:\n{forget_unit}"
    assert "--retry-lock" in forget_unit, f"forget takes an EXCLUSIVE lock; it must wait:\n{forget_unit}"
    for keep in ["--keep-daily 7", "--keep-weekly 4", "--keep-monthly 6"]:
        assert keep in forget_unit, f"retention {keep} lost in the move:\n{forget_unit}"

    # Prune is per REPOSITORY, not per job: it rewrites pack files for everyone's snapshots,
    # so there is one unit per destination and not one per job.
    prune_unit = on.succeed("systemctl cat restic-prune-rsyncnet.service")
    assert " prune" in prune_unit, prune_unit
    assert "unlock" in prune_unit, f"a stale lock would block prune forever:\n{prune_unit}"
    on.fail("systemctl cat restic-prune-daily-rsyncnet.service")

    # Nothing verified a backup on this fleet before the check unit existed: the nixpkgs
    # module only runs `check` when checkOpts is non-empty, and it never was.
    # The check unit's ExecStart is a generated SCRIPT, so the unit file only names a store
    # path — assert against the script body, or the test passes on the filename alone.
    check_script = on.succeed(
        "systemctl show restic-check-rsyncnet.service -p ExecStart --value"
        " | grep -oE '/nix/store/[^ ;}]+' | head -1"
    ).strip()
    check_body = on.succeed(f"cat {check_script}")
    assert "restic" in check_body and " check " in check_body, check_body
    assert "--read-data-subset" in check_body, f"check reads no pack data, so bit rot is invisible:\n{check_body}"

    # All three run on their own timers, not on the backup's.
    for t in [
        "restic-forget-daily-rsyncnet.timer",
        "restic-prune-rsyncnet.timer",
        "restic-check-rsyncnet.timer",
    ]:
        on.succeed(f"systemctl is-enabled {t}")

    # THE FAILURE PATH. No repository is reachable here, so the check must fail — and it must
    # still publish check_success=0 plus a run timestamp. A check that fails silently is
    # indistinguishable from one that never ran, which is the whole failure this guards.
    on.fail("systemctl start restic-check-rsyncnet.service")
    m = on.succeed("cat ${metricsDir}/backup-restic-checksuccess-rsyncnet.prom")
    assert 'backup_restic_check_success{restic_dest="rsyncnet"} 0' in m, m
    ts = on.succeed("cat ${metricsDir}/backup-restic-lastcheck-rsyncnet.prom")
    assert "backup_restic_last_check_timestamp_seconds" in ts, ts

    # ---- a REAL repository: the cross product, and what retention may delete ----
    two.wait_for_unit("multi-user.target")
    two.succeed("echo one > /srv/data/file")

    restic = (
        "restic -r ${localRepo} -p /etc/restic-local-password --insecure-no-password=false"
    )

    def snapshots(args=""):
        out = two.succeed(f"{restic} snapshots --json {args}")
        return [s["short_id"] for s in (json.loads(out) or [])]

    # FAN-OUT. One job declaration, one independent backup unit per ENABLED destination —
    # this is what phase 2 buys with a single `destinations.b2` entry. The switched-off
    # destination grows nothing, but is still reported, which is the distinction the board
    # draws.
    two.succeed("systemctl cat restic-backups-daily-local.service")
    two.succeed("systemctl cat restic-backups-daily-secondary.service")
    two.fail("systemctl cat restic-backups-daily-rsyncnet.service")
    two.fail("systemctl cat restic-prune-rsyncnet.service")

    # Retention runs for EVERY destination, because a snapshot's lifetime belongs to the host
    # that wrote it...
    two.succeed("systemctl cat restic-forget-daily-local.service")
    two.succeed("systemctl cat restic-forget-daily-secondary.service")
    # ...but prune and check are repository-wide and belong to ONE host. `maintenance` is
    # opt-in precisely so that the hosts phase 3 adds do not all join the fight over one
    # repository's exclusive lock, and this is that distinction pinned.
    two.succeed("systemctl cat restic-prune-local.service")
    two.fail("systemctl cat restic-prune-secondary.service")
    two.fail("systemctl cat restic-check-secondary.service")

    m = two.succeed("systemctl start backup-restic-status.service && cat ${metricsDir}/backup-restic-status.prom")
    assert 'backup_restic_enabled{restic_job="daily",restic_dest="local"} 1' in m, m
    assert 'backup_restic_enabled{restic_job="daily",restic_dest="secondary"} 1' in m, m
    assert 'backup_restic_enabled{restic_job="daily",restic_dest="rsyncnet"} 0' in m, m

    # The module initialises the repository on first run.
    two.succeed("systemctl start restic-backups-daily-local.service")
    m = two.succeed("cat ${metricsDir}/backup-restic-lastsuccess-daily-local.prom")
    assert 'backup_restic_last_success_timestamp_seconds{restic_job="daily",restic_dest="local"}' in m, m

    # The second destination is a SEPARATE repository with its own history, not a copy of the
    # first: fan-out, not replication (ADR-0035). Both hold the data after their own run.
    two.succeed("systemctl start restic-backups-daily-secondary.service")
    out = two.succeed(
        "restic -r ${secondaryRepo} -p /etc/restic-local-password snapshots --json --tag daily"
    )
    assert len(json.loads(out) or []) == 1, out

    # A second snapshot of this host's own job — the one retention is allowed to expire.
    two.succeed("echo two > /srv/data/file")
    two.succeed("systemctl start restic-backups-daily-local.service")
    mine = snapshots("--host two --tag daily")
    assert len(mine) == 2, f"expected 2 snapshots for this host's daily job, got {mine}"

    # Now the two kinds of bystander an unscoped `forget` would destroy: ANOTHER HOST's
    # snapshots (the fleet shares one repository) and ANOTHER JOB's on this host (telemetry
    # keeps 7 days, daily keeps months — one policy must not be applied to the other's
    # snapshots).
    two.succeed(f"{restic} backup --host otherhost --tag daily /srv/data")
    two.succeed(f"{restic} backup --host otherhost --tag daily /srv/data")
    two.succeed(f"{restic} backup --tag telemetry /srv/data")
    two.succeed(f"{restic} backup --tag telemetry /srv/data")
    foreign_before = snapshots("--host otherhost")
    telemetry_before = snapshots("--host two --tag telemetry")
    assert len(foreign_before) == 2, foreign_before
    assert len(telemetry_before) == 2, telemetry_before

    # --keep-last 1, so retention MUST delete exactly one snapshot: the older of this host's
    # own daily pair. If the filters were missing, the same policy would cut the other host's
    # history and the other job's down to one as well.
    two.succeed("systemctl start restic-forget-daily-local.service")

    mine_after = snapshots("--host two --tag daily")
    assert len(mine_after) == 1, f"retention did not apply to its own job: {mine_after}"
    assert mine_after[0] == mine[-1], f"retention kept the wrong snapshot: {mine_after} of {mine}"
    assert snapshots("--host otherhost") == foreign_before, (
        "retention expired ANOTHER HOST's snapshots — the repository is shared, so an "
        f"unscoped forget silently deletes other hosts' history: {foreign_before} -> "
        f"{snapshots('--host otherhost')}"
    )
    assert snapshots("--host two --tag telemetry") == telemetry_before, (
        "retention expired ANOTHER JOB's snapshots on this host: "
        f"{telemetry_before} -> {snapshots('--host two --tag telemetry')}"
    )

    f = two.succeed("cat ${metricsDir}/backup-restic-lastforget-daily-local.prom")
    assert 'backup_restic_last_forget_timestamp_seconds{restic_job="daily",restic_dest="local"}' in f, f

    # And the happy paths of the two repository-wide units, which only ever ran against an
    # unreachable repository above.
    two.succeed("systemctl start restic-prune-local.service")
    p = two.succeed("cat ${metricsDir}/backup-restic-lastprune-local.prom")
    assert 'backup_restic_last_prune_timestamp_seconds{restic_dest="local"}' in p, p

    two.succeed("systemctl start restic-check-local.service")
    c = two.succeed("cat ${metricsDir}/backup-restic-checksuccess-local.prom")
    assert 'backup_restic_check_success{restic_dest="local"} 1' in c, c

    print("SUCCESS: jobs × destinations generate one unit each; a disabled job and a")
    print("         switched-off destination both publish enabled=0; forget is scoped to")
    print("         this host and this job; prune/check are per repository; and a FAILED")
    print("         check still reports 0.")
  '';
}
