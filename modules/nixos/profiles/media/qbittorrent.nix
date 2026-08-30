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

    # qbittorrent-app has no network stack of its own — it lives inside gluetun's
    # namespace. When gluetun restarts, podman tears that namespace down and builds a
    # new one, so qbittorrent-app must go with it. `dependsOn` alone only generates
    # Requires=/After=, which order startup but do not propagate a restart: qBittorrent
    # would keep running, still `active`, holding sockets bound to addresses that no
    # longer exist. That is exactly what happened when gluetun's tunnel collapsed —
    # qBittorrent sat DHT-flat at 0 nodes with every torrent frozen in metaDL, and
    # restarting gluetun on its own would not have recovered it. BindsTo makes it follow
    # gluetun's lifecycle, PartOf makes a gluetun restart restart it. Guarded by the
    # netns-container-binding check.
    systemd.services.podman-qbittorrent-app = {
      bindsTo = [ "podman-gluetun.service" ];
      partOf = [ "podman-gluetun.service" ];
      # Wait for tun0 to actually have an address before qBittorrent starts. libtorrent
      # enumerates interfaces once, at startup: if it wins the race against wireguard it
      # binds eth0/lo only and never rebinds, leaving the UDP DHT socket on the bridge
      # where the kill-switch drops it (dht_nodes stuck at 0) while outbound TCP still
      # works and hides the problem.
      serviceConfig.ExecStartPre = [ "${cfg.gluetunWatchdog.readyCheck}" ];
    };

    # There is deliberately no `systemd.services.qbittorrent` here. One used to be
    # declared — `after`/`requires` on gluetun plus a preStart that seeded a default
    # qBittorrent.conf — but nothing ever gave it an ExecStart, because the application is
    # the container above and not a host service. systemd refused the unit outright
    # ("Service has no ExecStart=, ExecStop=, or SuccessAction=. Refusing.") on every
    # activation, so it sat there as a permanently `bad-setting` unit and its config
    # bootstrap never ran once. The container's own entrypoint writes that file anyway.
    #
    # Passwords still have to be set by hand in the WebUI on first start: qBittorrent
    # stores a PBKDF2 hash and offers no way to take one from a file or an environment
    # variable. The container prints a temporary password to its log on first run. The
    # value is kept in sops under `admin@torrent.palebluebytes.space` in the inkpotmonkey
    # user secrets, which is what ./qbittorrent-port-forward.nix authenticates with.

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
              # Restrict selection to port-forwarding-capable servers, i.e. ProtonVPN's
              # standard P2P servers. gluetun's filters are inclusion-only with no
              # "exclude Tor" flag, and Switzerland's pool includes Tor-over-VPN servers
              # (Swiss entry, but traffic exits via the Tor network — a German Tor exit
              # was observed). Tor and Secure Core servers don't offer port forwarding, so
              # PORT_FORWARD_ONLY excludes them and guarantees a plain Swiss P2P exit — the
              # right kind of server for qBittorrent and slskd. (This only filters server
              # SELECTION; forwarding itself is turned on in ./qbittorrent-port-forward.nix,
              # which is what makes this filter load-bearing rather than merely tidy.)
              PORT_FORWARD_ONLY = "on";
            };
        # ONLY the WebUI is published, and only to loopback (Caddy fronts it) — the same
        # rule slskd follows for its listen port, and for the same reason.
        #
        # The BitTorrent listen port is deliberately NOT published on the host. qBittorrent's
        # traffic exits via the VPN, so trackers and peers are told the VPN exit IP; a host
        # publish binds 0.0.0.0:6881 on kelpy's real address instead, and anything that
        # reaches it gets a BitTorrent handshake revealing which torrents this host is on.
        # That was not theoretical: with `6881:6881` published, peers were arriving on
        # 10.88.0.7 (the podman bridge) from the open internet while every outbound
        # connection went out over 10.2.0.2 — one peer saw both addresses.
        #
        # The inbound port that DOES work is the one ProtonVPN forwards on the VPN side:
        # see ./qbittorrent-port-forward.nix, which turns on gluetun's NAT-PMP client and
        # syncs the dynamically assigned port into qBittorrent's listener. That is the
        # complete version of the fix; publishing 6881 on the host never was, since it
        # exposed the real address without buying any inbound over the tunnel.
        ports = [
          "127.0.0.1:${toString settings.services.private.torrent.port}:${toString cfg.qbittorrent.webuiPort}/tcp" # WebUI
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
