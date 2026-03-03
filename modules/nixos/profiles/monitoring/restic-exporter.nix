# Restic Prometheus Exporter configuration
{
  config,
  pkgs,
  ...
}:
{
  # Set up a dedicated system user
  users.users.restic-exporter = {
    isSystemUser = true;
    group = "restic-exporter";
  };
  users.groups.restic-exporter = { };

  # Restic exporter service
  systemd.services.prometheus-restic-exporter = {
    description = "Prometheus Restic Exporter";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [
      pkgs.restic
      pkgs.openssh
      pkgs.coreutils
      pkgs.gnugrep
    ];
    environment = {
      RESTIC_PASSWORD_FILE = config.services.restic.backups.daily.passwordFile;
      LISTEN_ADDR = "127.0.0.1";
      LISTEN_PORT = "8567";
      REFRESH_INTERVAL = "3600";
      LOG_LEVEL = "INFO";
      # Configure SSH to use the credential key and a temporary known_hosts file
      # No longer need -F /dev/null as global config is removed
      RESTIC_SSH_COMMAND = "ssh -i $CREDENTIALS_DIRECTORY/ssh-key -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/run/prometheus-restic-exporter/known_hosts";
    };
    serviceConfig = {
      Type = "simple";
      User = "restic-exporter";
      Group = "restic-exporter";

      # Hardening
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      NoNewPrivileges = true;
      CapabilityBoundingSet = "";
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      MemoryDenyWriteExecute = true;
      LockPersonality = true;

      # Create a runtime directory for the service to store known_hosts
      RuntimeDirectory = "prometheus-restic-exporter";
      RuntimeDirectoryMode = "0700";

      # Securely load the SSH key from the user's home directory
      # Systemd (root) reads this and exposes it at $CREDENTIALS_DIRECTORY/ssh-key
      LoadCredential = [ "ssh-key:/persist/home/general/.ssh/id_ed25519" ];

      # Grant access to path-specific secrets
      BindReadOnlyPaths = [
        "${config.services.restic.backups.daily.passwordFile}:${config.services.restic.backups.daily.passwordFile}"
        "${config.services.restic.backups.daily.repositoryFile}:${config.services.restic.backups.daily.repositoryFile}"
      ];

      Restart = "on-failure";
      RestartSec = "30s";
    };
    script = ''
      export RESTIC_REPOSITORY=$(cat ${config.services.restic.backups.daily.repositoryFile})
      echo "Starting exporter for repository: $RESTIC_REPOSITORY"
      exec ${pkgs.prometheus-restic-exporter}/bin/restic-exporter.py
    '';
  };
}
