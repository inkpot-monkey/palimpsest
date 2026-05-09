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
    services.sonarr = {
      enable = true;
      openFirewall = false;
      group = "media";
    };

    systemd.services.sonarr.serviceConfig = {
      UMask = lib.mkForce "0002"; # Allow group-writable files
      ProtectSystem = "full";
      PrivateTmp = true;
      NoNewPrivileges = true;
    };

    # Ensure Sonarr can read qBittorrent downloads
    users.users.sonarr.extraGroups = [ "users" ];

    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        {
          directory = "/var/lib/sonarr";
          user = "sonarr";
          group = "media";
          mode = "0750";
        }
      ];
    };
  };
}
