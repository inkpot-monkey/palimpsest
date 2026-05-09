{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.custom.profiles.media;
in
{
  config = lib.mkIf cfg.enable {
    services.jellyfin = {
      enable = true;
      openFirewall = true;
    };

    # Jellyfin needs access to the 'users' group to read Transmission downloads
    users.users.jellyfin.extraGroups = [ "render" "users" ];

    systemd.tmpfiles.rules = [
      "Z /var/cache/jellyfin 0750 jellyfin jellyfin - -"
      "Z /var/lib/jellyfin 0700 jellyfin jellyfin - -"
    ];

    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        { directory = "/var/lib/jellyfin"; user = "jellyfin"; group = "media"; mode = "0750"; }
        { directory = "/var/cache/jellyfin"; user = "jellyfin"; group = "media"; mode = "0750"; }
      ];
    };
  };
}
