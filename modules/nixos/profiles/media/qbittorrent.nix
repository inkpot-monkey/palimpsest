{
  config,
  lib,
  settings,
  self,
  ...
}:

let
  cfg = config.custom.profiles.media;

  # Reproducible OCI images via digests
  images = {
    gluetun = {
      image = "qmcgaw/gluetun";
      digest = "sha256:f9cd584c6bb8c89e7e4c6d799c7547f600bc86842fd5636307543c001d929bbb";
    };
    qbittorrent = {
      image = "lscr.io/linuxserver/qbittorrent";
      digest = "sha256:c9990949e968e99333f47f49da7d16e81ba6e1469c8c46807a65b984c9e8b6ff";
    };
  };

  # Helper to construct the immutable image string
  mkImage = img: "${img.image}@${img.digest}";
in
{
  options.custom.profiles.media.qbittorrent = {
    puid = lib.mkOption {
      type = lib.types.str;
      default = "988";
      description = "PUID for the qBittorrent container.";
    };
    pgid = lib.mkOption {
      type = lib.types.str;
      default = "993";
      description = "PGID for the qBittorrent container.";
    };
    timezone = lib.mkOption {
      type = lib.types.str;
      default = "Europe/Madrid";
      description = "Timezone for the qBittorrent container.";
    };
    webuiPort = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Internal WebUI port for qBittorrent.";
    };
  };

  config = lib.mkIf cfg.enable {
    custom.profiles.podman.enable = true;

    users.users.qbittorrent = {
      isSystemUser = true;
      uid = 988;
      group = "qbittorrent";
      extraGroups = [ "media" ];
    };
    users.groups.qbittorrent = { };

    sops.secrets.protonvpn_env = lib.mkIf (!cfg.testMode) {
      sopsFile = self.lib.getSecretFile "media";
    };

    systemd.services.qbittorrent = {
      after = [ "podman-gluetun.service" ];
      requires = [ "podman-gluetun.service" ];
      serviceConfig = {
        Type = lib.mkForce "simple";
      };
      preStart = ''
                CONF_DIR="/var/lib/qbittorrent/config/qBittorrent"
                CONF_FILE="$CONF_DIR/qBittorrent.conf"
                mkdir -p "$CONF_DIR"

                # If file doesn't exist, create a basic one
                if [ ! -f "$CONF_FILE" ]; then
                  cat <<EOF > "$CONF_FILE"
        [LegalNotice]
        Accepted=true

        [Preferences]
        WebUI\Username=admin
        WebUI\Address=*
        WebUI\ServerDomains=*
        WebUI\Port=${toString cfg.qbittorrent.webuiPort}
        Downloads\SavePath=/downloads/
        Downloads\TempPath=/downloads/incomplete/
        EOF
                fi

                # NOTE: qBittorrent expects a PBKDF2 hash for the password in the config file.
                # Setting it declaratively via Nix is complex because it doesn't support environment variables.
                # Please set the password manually in the Web UI after first login!
                # The container prints a temporary password to the logs on first start.

                chown qbittorrent:media "$CONF_FILE"
      '';
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/qbittorrent/config 0755 qbittorrent media -"
    ];

    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        {
          directory = "/var/lib/qbittorrent";
          user = "qbittorrent";
          group = "media";
          mode = "0755";
        }
      ];
    };

    virtualisation.oci-containers.containers = {
      gluetun = {
        image = mkImage images.gluetun;
        environmentFiles = if cfg.testMode then [ ] else [ config.sops.secrets.protonvpn_env.path ];
        environment =
          if cfg.testMode then
            {
              VPN_SERVICE_PROVIDER = "custom";
              VPN_TYPE = "wireguard";
            }
          else
            {
              VPN_SERVICE_PROVIDER = "protonvpn";
              VPN_TYPE = "wireguard";
              SERVER_COUNTRIES = "Switzerland";
            };
        ports = [
          "127.0.0.1:${toString settings.services.private.torrent.port}:${toString cfg.qbittorrent.webuiPort}/tcp" # WebUI
          "6881:6881/tcp" # Torrent
          "6881:6881/udp" # Torrent
        ];
        extraOptions = [
          "--cap-add=NET_ADMIN"
          "--device=/dev/net/tun"
          "--runtime=runc"
        ];
      };

      qbittorrent-app = {
        image = mkImage images.qbittorrent;
        dependsOn = [ "gluetun" ];
        extraOptions = [
          "--network=container:gluetun"
          "--runtime=runc"
        ];
        environment = {
          PUID = cfg.qbittorrent.puid;
          PGID = cfg.qbittorrent.pgid;
          TZ = cfg.qbittorrent.timezone;
          WEBUI_PORT = toString cfg.qbittorrent.webuiPort;
        };
        volumes = [
          "/var/lib/qbittorrent/config:/config"
          "${cfg.mediaPath}/downloads:/downloads"
        ];
      };
    };
  };
}
