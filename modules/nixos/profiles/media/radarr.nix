{
  config,
  lib,
  ...
}:

let
  cfg = config.custom.profiles.media;
in
{
  config = lib.mkIf cfg.enable {
    services.radarr = {
      enable = true;
      openFirewall = false;
      group = "media";
    };

    # NOTE: PrivateUsers is disabled to avoid permission issues with Impermanence.
    # Impermanence creates the directory on the host with the host UID. With PrivateUsers=true,
    # the service runs in an isolated namespace and cannot write to the directory.
    # Also, systemd might create /var/lib/radarr/.config as root:root during activation due to
    # RequiresMountsFor, requiring manual deletion of that empty directory if it exists.
    systemd.services.radarr.serviceConfig = {
      PrivateUsers = lib.mkForce false;
      UMask = lib.mkForce "0002";
      ProtectSystem = "full";
      PrivateTmp = true;
      NoNewPrivileges = true;
    };

    users.users.radarr.extraGroups = [ "users" ];

    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        {
          directory = "/var/lib/radarr";
          user = "radarr";
          group = "media";
          mode = "0750";
        }
      ];
    };
  };
}
