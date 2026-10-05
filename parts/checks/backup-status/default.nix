{
  self,
  pkgs,
  inputs,
  ...
}:

# Restic backup status metrics (modules/nixos/profiles/backup.nix). Restic is switched off
# fleet-wide — DEFERRED, not blocked (palimpsest#150) — so the load-bearing behaviour is that a host
# which OWNS an off-site job still publishes it as a known-DISABLED edge — the Backups
# board must show "off", not "no data". This pins that: a host with reportJobs but the
# jobs disabled emits backup_restic_enabled = 0 for each, plus a check heartbeat.
#
# The enabled=1 value is a compile-time flip of the same line, and the last-success stamp
# is an ExecStartPost on the (currently non-existent) restic unit — both dormant while
# restic is off, so they are verified by eval rather than exercised here.

let
  metricsDir = "/var/lib/prometheus-node-exporter-text-files";
  backupModule = self + /modules/nixos/profiles/backup.nix;
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
    { lib, ... }:
    {
      imports = [
        backupModule
        inputs.sops-nix.nixosModules.sops
      ];
      _module.args.self = self;

      # ENABLED, so the out-of-band prune and check units exist. There is no reachable
      # repository in the VM and that is the point for `check`: its failure path is what
      # must still publish a metric.
      custom.profiles.backup = {
        enable = true;
        reportJobs = [ "daily" ];
      };
      services.restic.backups.daily.paths = [ "/etc/hostname" ];

      # Satisfy the sops assertions without a real key or file, and bypass decryption by
      # pointing the three restic secrets at plain /etc files — the same pattern
      # parts/checks/supernote and parts/checks/affine use. Nothing here decrypts: the units
      # only have to EXIST and, for the check, to fail in the right way.
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

      systemd.tmpfiles.rules = [ "d ${metricsDir} 0755 root root -" ];
    };

  testScript = ''
    off.wait_for_unit("multi-user.target")

    # Drive the oneshot directly (the timer only fixes *when*).
    off.succeed("systemctl start backup-restic-status.service")
    m = off.succeed("cat ${metricsDir}/backup-restic-status.prom")

    # Both owned jobs surface as known-disabled edges, not as missing data. The label is
    # `restic_job`, not the reserved `job` (which the scrape would overwrite to "node").
    assert 'backup_restic_enabled{restic_job="daily"} 0' in m, m
    assert 'backup_restic_enabled{restic_job="telemetry"} 0' in m, m
    # A heartbeat so a dead emitter is distinguishable from a healthy all-off host.
    assert "backup_restic_check_timestamp_seconds" in m, m

    # World-readable, or node-exporter (a different user) could never scrape it.
    mode = off.succeed("stat -c %a ${metricsDir}/backup-restic-status.prom").strip()
    assert mode == "644", f"status metrics must be world-readable, got {mode}"

    # ---- the ENABLED host: prune and check are OUT OF BAND ----
    on.wait_for_unit("multi-user.target")

    # The load-bearing property. `forget --prune` must NOT be in the backup unit's ExecStart:
    # ExecStartPost is where last-success is stamped, and it fires only when every ExecStart
    # step succeeded — so a prune failing on a contended lock would suppress the stamp for a
    # backup that actually succeeded, and the Backups board would go cold on a good night.
    backup_unit = on.succeed("systemctl cat restic-backups-daily.service")
    assert "forget" not in backup_unit, f"forget is welded back into the backup unit:\n{backup_unit}"
    assert "--prune" not in backup_unit, f"prune is welded back into the backup unit:\n{backup_unit}"

    # ...and it lives in its own unit instead, with the retention policy intact.
    prune_unit = on.succeed("systemctl cat restic-prune-daily.service")
    assert "forget --prune" in prune_unit, prune_unit
    for keep in ["--keep-daily 7", "--keep-weekly 4", "--keep-monthly 6"]:
        assert keep in prune_unit, f"retention {keep} lost in the move:\n{prune_unit}"

    # Nothing verified a backup on this fleet before the check unit existed: the nixpkgs
    # module only runs `check` when checkOpts is non-empty, and it never was.
    # The check unit's ExecStart is a generated SCRIPT, so the unit file only names a store
    # path — assert against the script body, or the test passes on the filename alone.
    on.succeed("systemctl cat restic-check-daily.service")
    check_script = on.succeed(
        "systemctl show restic-check-daily.service -p ExecStart --value"
        " | grep -oE '/nix/store/[^ ;}]+' | head -1"
    ).strip()
    check_body = on.succeed(f"cat {check_script}")
    assert "restic" in check_body and " check " in check_body, check_body
    assert "--read-data-subset" in check_body, f"check reads no pack data, so bit rot is invisible:\n{check_body}"

    # Both run on their own timers, not on the backup's.
    for t in ["restic-prune-daily.timer", "restic-check-daily.timer"]:
        on.succeed(f"systemctl is-enabled {t}")

    # THE FAILURE PATH. No repository is reachable here, so the check must fail — and it must
    # still publish check_success=0 plus a run timestamp. A check that fails silently is
    # indistinguishable from one that never ran, which is the whole failure this guards.
    on.fail("systemctl start restic-check-daily.service")
    m = on.succeed("cat ${metricsDir}/backup-restic-checksuccess-daily.prom")
    assert 'backup_restic_check_success{restic_job="daily"} 0' in m, m
    ts = on.succeed("cat ${metricsDir}/backup-restic-lastcheck-daily.prom")
    assert "backup_restic_last_check_timestamp_seconds" in ts, ts

    print("SUCCESS: a disabled-but-owned restic job publishes backup_restic_enabled=0;")
    print("         prune and check are out of band, and a FAILED check still reports 0.")
  '';
}
