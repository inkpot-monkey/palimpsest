{
  config,
  lib,
  ...
}:
let
  # Host-provided resolver for the encrypted restic sops source (ADR-0015): the
  # feature names the secret group, the host says where it lives.
  resticSops = config.custom.platform.secretFile "restic";
in
{
  # The `restic.enable` option is declared centrally in the contract home-profile
  # vocabulary (contract/home-profiles.nix); this module supplies its config.
  # Secrets + the repo template go through the backend-neutral platform seam (ADR-0021),
  # never sops directly: the feature declares logical secrets; the host binding realizes them.
  config = lib.mkIf config.custom.home.profiles.restic.enable {
    custom.platform.secrets = {
      restic_repo = {
        source = resticSops;
        key = "restic/repo";
      };
      restic_password = {
        source = resticSops;
        key = "restic/password";
      };
      restic_ssh_private = {
        source = resticSops;
        key = "restic/ssh/private";
      };
    };
    custom.platform.secretTemplates."restic-repo".content = ''
      ${config.custom.platform.placeholder.restic_repo}:backups
    '';

    services.restic.enable = true;
    services.restic.backups.daily = {
      initialize = true;
      passwordFile = config.custom.platform.secretPaths.restic_password;
      repositoryFile = config.custom.platform.templatePaths."restic-repo";
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
        "sftp.command='ssh -F /dev/null -i ${config.custom.platform.secretPaths.restic_ssh_private} zh2046@zh2046.rsync.net -s sftp'"
      ];
    };
  };
}
