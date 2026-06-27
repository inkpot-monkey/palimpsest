{
  config,
  lib,
  pkgs,
  self,
  ...
}:

let
  cfg = config.custom.profiles.backup;
  sftpCommand = "sftp.command='ssh -F /dev/null -i ${config.sops.secrets.restic_ssh_private.path} zh2046@zh2046.rsync.net -s sftp'";
in
{
  options.custom.profiles.backup = {
    enable = lib.mkEnableOption "daily restic backups configuration";

    monitoringTelemetry = {
      enable = lib.mkEnableOption "VictoriaMetrics snapshot backup to rsync.net (every 6h, keep 7d)";
    };
  };

  config = lib.mkMerge [
    # Restic secrets: shared by daily backup and monitoring telemetry backup.
    # Loaded whenever either is enabled.
    (lib.mkIf (cfg.enable || cfg.monitoringTelemetry.enable) {
      sops.secrets.restic_password = {
        key = "restic/password";
        sopsFile = self.lib.getSecretFile "restic";
      };
      sops.secrets.restic_repo = {
        key = "restic/repo";
        sopsFile = self.lib.getSecretFile "restic";
      };
      sops.secrets.restic_ssh_private = {
        key = "restic/ssh/private";
        sopsFile = self.lib.getSecretFile "restic";
      };

      sops.templates."restic-repo".content = ''
        ${config.sops.placeholder.restic_repo}:backups
      '';
    })

    # Daily service-state backup.
    (lib.mkIf cfg.enable {
      services.restic.backups.daily = {
        initialize = true;
        passwordFile = config.sops.secrets.restic_password.path;
        repositoryFile = config.sops.templates."restic-repo".path;
        timerConfig = {
          OnCalendar = "00/6:00";
          Persistent = true;
        };
        pruneOpts = [
          "--keep-daily 7"
          "--keep-weekly 4"
          "--keep-monthly 6"
        ];
        extraOptions = [
          # Use a dedicated Restic SSH key; rsync.net's public key is trusted in base.nix.
          # -F /dev/null avoids permission issues with ~/.ssh/config in the Nix store.
          sftpCommand
        ];
      };
    })

    # Telemetry backup: VictoriaMetrics consistent snapshot → rsync.net every 6h.
    # Uses VM's /snapshot/create API so the backup is always consistent; local
    # snapshots are deleted after each successful backup (restic deduplicates).
    # RPO ≈ 6h. See ADR-0028.
    (lib.mkIf cfg.monitoringTelemetry.enable {
      services.restic.backups.telemetry = {
        initialize = true;
        passwordFile = config.sops.secrets.restic_password.path;
        repositoryFile = config.sops.templates."restic-repo".path;
        timerConfig = {
          OnCalendar = "00/6:00";
          Persistent = true;
        };
        pruneOpts = [ "--keep-daily 7" ];
        extraOptions = [ sftpCommand ];
        paths = [ "/var/cache/victoriametrics/snapshots" ];
        backupPrepareCommand = ''
          ${pkgs.curl}/bin/curl -sf http://localhost:8428/snapshot/create >/dev/null
        '';
        backupCleanupCommand = ''
          ${pkgs.curl}/bin/curl -sf http://localhost:8428/snapshot/deleteAll >/dev/null || true
        '';
      };
    })
  ];
}
