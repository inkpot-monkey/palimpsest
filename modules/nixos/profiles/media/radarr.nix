{
  config,
  lib,
  settings,
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

    systemd.services.radarr.serviceConfig = {
      UMask = lib.mkForce "0002";
      ProtectSystem = "full";
      PrivateTmp = true;
      NoNewPrivileges = true;
    };

    users.users.radarr.extraGroups = [ "users" ];

    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        { directory = "/var/lib/radarr"; user = "radarr"; group = "media"; mode = "0750"; }
      ];
    };
  };
}
