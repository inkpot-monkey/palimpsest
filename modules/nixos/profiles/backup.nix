{
  config,
  lib,
  ...
}:

{
  sops.secrets.restic_password = { };

  services.restic.backups.daily = {
    initialize = true;
    passwordFile = config.sops.secrets.restic_password.path;
    repository = "sftp:zh2046@zh2046.rsync.net:backups";
    paths = lib.mkDefault [ "/persistent" ];
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
      "sftp.command='ssh -i /etc/ssh/ssh_host_ed25519_key -o StrictHostKeyChecking=accept-new zh2046@zh2046.rsync.net -s sftp'"
    ];
  };

  services.prometheus.exporters.restic = {
    enable = true;
    repository = "sftp:zh2046@zh2046.rsync.net:backups";
    passwordFile = config.sops.secrets.restic_password.path;
    refreshInterval = 3600;
    extraFlags = [
      "--restic-arguments=\"-o sftp.command='ssh -i /etc/ssh/ssh_host_ed25519_key -o StrictHostKeyChecking=accept-new zh2046@zh2046.rsync.net -s sftp'\""
    ];
  };

  # Open the exporter port for Tailscale
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [
    config.services.prometheus.exporters.restic.port
  ];
}
