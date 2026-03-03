{
  config,
  pkgs,
  self,
  settings,
  ...
}:
let
  domain = config.networking.domain;
in
{
  imports = [ self.nixosProfiles.podman ];

  systemd.tmpfiles.rules = [
    "d /var/lib/transmission/config 0755 1000 100 -"
    "d /var/lib/transmission/Downloads 0755 1000 100 -"
  ];

  sops.secrets.protonvpn_env = {
    sopsFile = config.sops.defaultSopsFile;
  };

  environment.persistence."/persistent" = {
    hideMounts = true;
    directories = [
      # Persist the standard Transmission directory
      "/var/lib/transmission"
    ];
  };

  virtualisation.oci-containers.containers = {
    gluetun = {
      image = "qmcgaw/gluetun:latest";
      environmentFiles = [ config.sops.secrets.protonvpn_env.path ];
      environment = {
        VPN_SERVICE_PROVIDER = "protonvpn";
        VPN_TYPE = "wireguard";
        SERVER_COUNTRIES = "Switzerland";
      };
      ports = [ "${toString settings.services.private.torrent.port}:9091/tcp" ];
      extraOptions = [
        "--cap-add=NET_ADMIN"
        "--device=/dev/net/tun"
        "--runtime=runc"
      ];
    };

    transmission = {
      image = "lscr.io/linuxserver/transmission:latest";
      dependsOn = [ "gluetun" ];
      extraOptions = [
        "--network=container:gluetun"
        "--runtime=runc"
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
}
