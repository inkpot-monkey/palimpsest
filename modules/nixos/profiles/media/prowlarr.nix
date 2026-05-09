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
    systemd.tmpfiles.rules = [
      "Z /var/lib/prowlarr 0750 prowlarr media - -"
    ];

    services.prowlarr = {
      enable = true;
      openFirewall = false;
    };

    services.flaresolverr = {
      enable = true;
      openFirewall = false;
    };

    systemd.services.prowlarr.serviceConfig = {
      DynamicUser = lib.mkForce false;
      StateDirectory = lib.mkForce ""; # Fix 'Invalid cross-device link' with Impermanence
      ProtectSystem = "full";
      PrivateTmp = true;
      NoNewPrivileges = true;
    };

    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        { directory = "/var/lib/prowlarr"; user = "prowlarr"; group = "media"; mode = "0750"; }
      ];
    };
  };
}
