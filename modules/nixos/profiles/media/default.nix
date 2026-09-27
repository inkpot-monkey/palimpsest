{
  config,
  lib,
  settings,
  ...
}:

let
  cfg = config.custom.profiles.media;

  # The whole profile moves as one unit, so one answer covers all three web UIs:
  # when the registry says this stack runs off the Caddy edge, the container ports
  # have to be published somewhere the edge can actually reach over the tailnet
  # instead of loopback. Read off `torrent` as the profile's representative entry —
  # jellyfin/slskd move with it by construction.
  offEdge = (settings.services.private.torrent.origin or null) == config.networking.hostName;
in
{
  imports = [
    ./qbittorrent.nix
    ./qbittorrent-port-forward.nix
    ./qbittorrent-preferences.nix
    ./gluetun-watchdog.nix
    ./jellyfin.nix
    ./slskd.nix
  ];

  options.custom.profiles.media = {
    enable = lib.mkEnableOption "Media server and automation configuration";
    mediaPath = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/media";
      example = "/var/cache/media";
      description = ''
        The base path for media storage.

        Override it on a host whose root is a tmpfs: the default lands on the
        impermanent root, which on the rk1 nodes is a 2G ramdisk that downloads
        fill immediately. Those hosts keep bulk data on the NVMe `/var/cache`
        subtree, as Navidrome and Stump do.
      '';
    };

    # Internal, not for hosts to set: derived above so the two container port
    # publishes (qbittorrent.nix, slskd.nix) share one definition rather than
    # each re-deriving it and drifting.
    bindHost = lib.mkOption {
      type = lib.types.str;
      internal = true;
      readOnly = true;
      default = if offEdge then "0.0.0.0" else "127.0.0.1";
      description = "Address the media web UIs are published on.";
    };
    testMode = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable test mode (mock secrets).";
    };
  };

  config = lib.mkIf cfg.enable {
    # Off-edge only, and on tailscale0 ALONE — never openFirewall, which would put
    # the torrent and Soulseek UIs on the home LAN. On the edge these stay on
    # loopback and the firewall is untouched.
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = lib.mkIf offEdge [
      settings.services.private.torrent.port
      settings.services.private.slskd.port
      settings.services.public.jellyfin.port
    ];

    # Shared group for media access
    users.groups.media = {
      gid = 993;
    };

    # --- 2. Shared Directories ---
    systemd.tmpfiles.rules = [
      "d ${cfg.mediaPath} 2775 root media - -"
      "d ${cfg.mediaPath}/movies 2775 root media - -"
      "d ${cfg.mediaPath}/series 2775 root media - -"
      "d ${cfg.mediaPath}/tv 2775 root media - -"
      "d ${cfg.mediaPath}/downloads 2775 qbittorrent media - -"
    ];

    # Only when the tree actually sits under the impermanent root. Pointed at a durable
    # NVMe subtree (/var/cache on the rk1 nodes) it is already persistent, and naming it
    # here is worse than redundant: impermanence demands the underlying filesystem be
    # neededForBoot, which /var/cache is not, so the eval fails outright.
    environment.persistence."/persistent" =
      lib.mkIf (config.custom.profiles.impermanence.enable && lib.hasPrefix "/var/lib" cfg.mediaPath)
        {
          directories = [
            {
              directory = cfg.mediaPath;
              user = "root";
              group = "media";
              mode = "2775";
            }
          ];
        };
  };
}
