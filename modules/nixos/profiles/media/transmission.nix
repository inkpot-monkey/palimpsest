{
  config,
  lib,
  settings,
  self,
  inputs,
  ...
}:

let
  cfg = config.custom.profiles.transmission;

  # Reproducible OCI images via digests
  images = {
    gluetun = {
      image = "qmcgaw/gluetun";
      digest = "sha256:fcbe2e4919b05dd9653a6ce64304bd4f532d5b52e1356aaec4430713fa53c839";
    };
    transmission = {
      image = "lscr.io/linuxserver/transmission";
      digest = "sha256:bd9d4858be1138787cd3e4d05d2f8be72ab24685117361f47184f95d9215d859";
    };
  };

  # Helper to construct the immutable image string
  mkImage = img: "${img.image}@${img.digest}";
in
{
  options.custom.profiles.transmission = {
    enable = lib.mkEnableOption "Transmission torrent client with Gluetun VPN configuration";
    testMode = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable test mode (mock VPN configuration).";
    };
    gluetunImage = lib.mkOption {
      type = lib.types.str;
      default = mkImage images.gluetun;
      description = "Gluetun image to use (digest recommended).";
    };
    transmissionImage = lib.mkOption {
      type = lib.types.str;
      default = mkImage images.transmission;
      description = "Transmission image to use (digest recommended).";
    };
  };

  config = lib.mkIf cfg.enable {
    custom.profiles.podman.enable = true;

    systemd.tmpfiles.rules = [
      "d /var/lib/transmission/config 0755 1000 100 -"
      "d /var/lib/transmission/Downloads 0775 1000 100 -"
    ];

    sops.secrets.protonvpn_env = lib.mkIf (!cfg.testMode) {
      sopsFile = self.lib.getSecretFile "media";
    };

    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        "/var/lib/transmission"
      ];
    };

    virtualisation.oci-containers.containers = {
      gluetun = {
        image = cfg.gluetunImage;
        environmentFiles = if cfg.testMode then [ ] else [ config.sops.secrets.protonvpn_env.path ];
        environment =
          if cfg.testMode then
            {
              VPN_SERVICE_PROVIDER = "custom";
              VPN_TYPE = "wireguard";
              # The test suite will provide a custom Wireguard config
            }
          else
            {
              VPN_SERVICE_PROVIDER = "protonvpn";
              VPN_TYPE = "wireguard";
              SERVER_COUNTRIES = "Switzerland";
            };
        ports = [ "${toString settings.services.private.torrent.port}:9091/tcp" ];
        extraOptions = [
          "--cap-add=NET_ADMIN"
          "--device=/dev/net/tun"
          "--runtime=runc"
          "--no-healthcheck"
        ];
      };

      transmission = {
        image = cfg.transmissionImage;
        dependsOn = [ "gluetun" ];
        extraOptions = [
          "--network=container:gluetun"
          "--runtime=runc"
          "--no-healthcheck"
        ];
        environment = {
          PUID = "1000";
          PGID = "100";
        };
        volumes = [
          "/var/lib/transmission/config:/config"
          "/var/lib/transmission/Downloads:/downloads"
        ];
      };
    };
  };
}
