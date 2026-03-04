{
  config,
  lib,
  ...
}:

lib.mkIf (config.identity.profile == "gui") {
  sops.secrets.restic_repo = {
    key = "restic/repo";
    sopsFile = ../../../secrets/secrets.yaml;
  };
  sops.secrets.restic_password = {
    key = "restic/password";
    sopsFile = ../../../secrets/secrets.yaml;
  };
  sops.secrets.restic_ssh_private = {
    key = "restic/ssh/private";
    sopsFile = ../../../secrets/secrets.yaml;
  };
  sops.templates."restic-repo".content = ''
    ${config.sops.placeholder.restic_repo}:backups
  '';

  services.restic.enable = true;
  services.restic.backups.daily = {
    initialize = true;
    passwordFile = config.sops.secrets.restic_password.path;
    repositoryFile = config.sops.templates."restic-repo".path;
    paths = [
      config.home.homeDirectory
    ];
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
      # Use a dedicated Restic SSH key for isolation.
      # -F /dev/null avoids permission issues with ~/.ssh/config in the Nix store.
      "sftp.command='ssh -F /dev/null -i ${config.sops.secrets.restic_ssh_private.path} zh2046@zh2046.rsync.net -s sftp'"
    ];
  };
}
