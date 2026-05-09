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
    services.bazarr = {
      enable = true;
      openFirewall = true;
      group = "media";
    };

    systemd.services.bazarr.serviceConfig = {
      UMask = lib.mkForce "0002";
      ProtectSystem = "full";
      PrivateTmp = true;
      NoNewPrivileges = true;
    };

    users.users.bazarr.extraGroups = [ "users" ];

    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        {
          directory = "/var/lib/bazarr";
          user = "bazarr";
          group = "media";
          mode = "0750";
        }
      ];
    };
  };
}
