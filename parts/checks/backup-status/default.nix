{
  self,
  pkgs,
  inputs,
  ...
}:

# Restic backup status metrics (modules/nixos/profiles/backup.nix). Restic is switched off
# fleet-wide while rsync.net is unreachable, so the load-bearing behaviour is that a host
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
  nodes.node =
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

  testScript = ''
    node.wait_for_unit("multi-user.target")

    # Drive the oneshot directly (the timer only fixes *when*).
    node.succeed("systemctl start backup-restic-status.service")
    m = node.succeed("cat ${metricsDir}/backup-restic-status.prom")

    # Both owned jobs surface as known-disabled edges, not as missing data.
    assert 'backup_restic_enabled{job="daily"} 0' in m, m
    assert 'backup_restic_enabled{job="telemetry"} 0' in m, m
    # A heartbeat so a dead emitter is distinguishable from a healthy all-off host.
    assert "backup_restic_check_timestamp_seconds" in m, m

    # World-readable, or node-exporter (a different user) could never scrape it.
    mode = node.succeed("stat -c %a ${metricsDir}/backup-restic-status.prom").strip()
    assert mode == "644", f"status metrics must be world-readable, got {mode}"

    print("SUCCESS: a disabled-but-owned restic job publishes backup_restic_enabled=0.")
  '';
}
