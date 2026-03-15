{
  config,
  lib,
  ...
}:

let
  cfg = config.custom.profiles.backup;
in
{
  options.custom.profiles.backup = {
    enable = lib.mkEnableOption "daily restic backups configuration";
  };

  config = lib.mkIf cfg.enable {
    # The restic secrets
    sops.secrets.restic_password.key = "restic/password";
    sops.secrets.restic_repo.key = "restic/repo";
    sops.secrets.restic_ssh_private.key = "restic/ssh/private";

    sops.templates."restic-repo".content = ''
      ${config.sops.placeholder.restic_repo}:backups
    '';

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
        "sftp.command='ssh -F /dev/null -i ${config.sops.secrets.restic_ssh_private.path} zh2046@zh2046.rsync.net -s sftp'"
      ];
    };
  };
}
