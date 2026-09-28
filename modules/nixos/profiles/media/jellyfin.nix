{
  config,
  lib,
  pkgs,
  self,
  settings,
  ...
}:

let
  cfg = config.custom.profiles.media;
  jcfg = cfg.jellyfin;
  port = settings.services.public.jellyfin.port;
in
{
  config = lib.mkIf cfg.enable {
    services.jellyfin = {
      enable = true;
      # NOT openFirewall: that opens 8096 on every interface, which off-edge would
      # mean the home LAN as well as the tailnet. media/default.nix opens the port
      # on tailscale0 alone when this stack runs off the Caddy edge; on the edge
      # Caddy reaches it over loopback and nothing needs opening at all.
      openFirewall = false;
    };

    # Jellyfin needs access to the 'users' group to read Transmission downloads
    users.users.jellyfin.extraGroups = [
      "render"
      "users"
    ];

    systemd.tmpfiles.rules = [
      "Z /var/cache/jellyfin 0750 jellyfin jellyfin - -"
      "Z /var/lib/jellyfin 0700 jellyfin jellyfin - -"
    ];

    # Post-start provisioner (opt-in). Jellyfin has no declarative path for either its
    # startup wizard or its libraries, so this drives Jellyfin's own API — the same
    # shape as custom.profiles.homeassistant.provision. Idempotent in both halves (a
    # completed wizard is skipped, an existing library is left alone) and fail-loud.
    #
    # Not cosmetic: moving the media stack to rk1b produced a running Jellyfin sat
    # beside 15G of media with no library pointing at any of it, because that state
    # lived only in kelpy's UI and kelpy's copy was 14K of nothing.
    systemd.services.jellyfin-provision = lib.mkIf jcfg.provision.enable {
      description = "Complete Jellyfin's startup wizard and declare its libraries";
      after = [ "jellyfin.service" ];
      requires = [ "jellyfin.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        JELLYFIN_URL = "http://127.0.0.1:${toString port}";
        JELLYFIN_ADMIN_USER = jcfg.provision.adminUser;
        JELLYFIN_UI_CULTURE = jcfg.provision.uiCulture;
        JELLYFIN_COUNTRY = jcfg.provision.metadataCountry;
        JELLYFIN_LANGUAGE = jcfg.provision.metadataLanguage;
        JELLYFIN_LIBRARIES = builtins.toJSON jcfg.provision.libraries;
      };
      startLimitIntervalSec = 900;
      startLimitBurst = 8;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 30;
        LoadCredential = [ "admin_password:${config.sops.secrets.jellyfin_admin_password.path}" ];
        ExecStart = pkgs.writeShellScript "jellyfin-provision" ''
          set -euo pipefail
          for _ in $(seq 1 90); do
            code=$(${pkgs.curl}/bin/curl -s -o /dev/null -w '%{http_code}' \
              "$JELLYFIN_URL/System/Info/Public" || true)
            [ "$code" = "200" ] && break
            sleep 2
          done
          exec ${pkgs.python3}/bin/python3 ${./jellyfin-provision.py}
        '';
      };
    };

    sops.secrets.jellyfin_admin_password = lib.mkIf jcfg.provision.enable {
      sopsFile = self.lib.getSecretFile "media";
      key = "jellyfin_admin_password";
    };

    # /var/lib/jellyfin always needs persisting on an impermanent host. /var/cache/jellyfin
    # only does when /var/cache is part of the impermanent root — on a host that mounts it
    # as its own durable filesystem (the rk1 nodes' NVMe) the cache is already durable, and
    # listing it here fails eval outright: impermanence requires the underlying filesystem
    # to be neededForBoot, which a data mount is not.
    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        {
          directory = "/var/lib/jellyfin";
          user = "jellyfin";
          group = "media";
          mode = "0750";
        }
      ]
      ++ lib.optional (!(config.fileSystems ? "/var/cache")) {
        directory = "/var/cache/jellyfin";
        user = "jellyfin";
        group = "media";
        mode = "0750";
      };
    };
  };
}
