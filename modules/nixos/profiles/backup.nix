{
  config,
  lib,
  pkgs,
  ...
}:

{
  services.restic.backups.daily = {
    initialize = true;
    passwordFile = config.sops.secrets.restic-password.path;
    repositoryFile = config.sops.secrets.restic_repo.path;
    paths = [ "/home/general" ];
    timerConfig = {
      OnCalendar = "00/6:00";
      Persistent = true;
    };
    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 6"
    ];
  };

  # Retry backup if it fails (e.g. temporary network drop)
  systemd = {
    services = {
      restic-backups-daily = {
        serviceConfig = {
          Restart = "on-failure";
          RestartSec = "1m";
          # Add ExecStartPre hook separately since it needs to wrap the existing service
          ExecStartPre = lib.mkBefore [
            "${pkgs.coreutils}/bin/sleep 60"
            (pkgs.writeShellScript "restic-unlock" ''
              export RESTIC_REPOSITORY=$(cat ${config.services.restic.backups.daily.repositoryFile})
              export RESTIC_PASSWORD_FILE=${config.services.restic.backups.daily.passwordFile}
              ${pkgs.restic}/bin/restic unlock || true
            '')
          ];
        };
        environment = {
          # Explicitly specify SSH command with identity file to avoid relying on global config
          RESTIC_SSH_COMMAND = "ssh -i /persist/home/general/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=60 -o ServerAliveCountMax=240";
        };
      };

      # Restic stats for Prometheus
      restic-stats = {
        serviceConfig.Type = "oneshot";
        environment = {
          # Also ensure the stats service uses the correct key
          RESTIC_SSH_COMMAND = "ssh -i /persist/home/general/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new";
        };
        path = with pkgs; [
          restic
          jq
          coreutils
        ];
        # Remove redundant environment to avoid conflict with -r flag in restic
        # The script below sets the same variables correctly from secrets.
        script = ''
          prom_file="/var/lib/prometheus-node-exporter-text-files/restic.prom"
          mkdir -p $(dirname $prom_file)

          # Get repository and password
          export RESTIC_REPOSITORY=$(cat ${config.services.restic.backups.daily.repositoryFile})
          export RESTIC_PASSWORD_FILE=${config.services.restic.backups.daily.passwordFile}

          # Get Snapshots Count
          echo "# HELP restic_snapshots_count Total number of snapshots" > $prom_file
          echo "# TYPE restic_snapshots_count gauge" >> $prom_file
          snapshots=$(restic snapshots --json)
          count=$(echo $snapshots | jq 'length')
          echo "restic_snapshots_count $count" >> $prom_file

          # Get Latest Snapshot Timestamp
          echo "# HELP restic_backup_timestamp Last backup completion timestamp" >> $prom_file
          echo "# TYPE restic_backup_timestamp gauge" >> $prom_file
          last_timestamp=$(echo $snapshots | jq -r 'last | .time | fromdateiso8601')
          echo "restic_backup_timestamp $last_timestamp" >> $prom_file

          # Get Latest Snapshot Stats (Size)
          stats=$(restic stats latest --json)

          echo "# HELP restic_repository_total_size_bytes Total size of the repository in bytes" >> $prom_file
          echo "# TYPE restic_repository_total_size_bytes gauge" >> $prom_file
          size=$(echo $stats | jq '.total_size')
          echo "restic_repository_total_size_bytes $size" >> $prom_file

          echo "# HELP restic_repository_files_count Total number of files in latest snapshot" >> $prom_file
          echo "# TYPE restic_repository_files_count gauge" >> $prom_file
          files=$(echo $stats | jq '.total_file_count')
          echo "restic_repository_files_count $files" >> $prom_file
        '';
      };
    };

    timers.restic-stats = {
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
      };
      wantedBy = [ "timers.target" ];
    };
  };
}
