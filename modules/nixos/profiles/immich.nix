{
  config,
  lib,
  settings,
  ...
}:

let
  cfg = config.custom.profiles.immich;
  svc = settings.services.private.immich;

  # Immich may run on the edge (Caddy proxies to loopback) or off it (Caddy on the
  # edge proxies across the tailnet to `origin`). The binding has to follow, so it
  # is derived from the registry rather than set twice and left to drift.
  offEdge = (svc.origin or null) == config.networking.hostName;
in
{
  options.custom.profiles.immich = {
    enable = lib.mkEnableOption "Immich photo library";

    mediaLocation = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/immich";
      example = "/var/cache/immich";
      description = ''
        Where Immich keeps originals, thumbnails and transcodes.

        Override it on a host whose root is a tmpfs: the default lands on the
        impermanent root, which on the rk1 nodes is a 2G ramdisk that a photo
        library fills immediately. Those hosts keep data on the NVMe `/var/cache`
        subtree, the same as Navidrome and Stump.
      '';
    };

    databaseDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/postgresql";
      example = "/var/cache/postgresql";
      description = ''
        Where Immich's postgres keeps its cluster.

        Moves for the same reason as `mediaLocation`, and matters more: the
        originals are only pixels, but albums, faces, people and share links live
        here and nowhere else.
      '';
    };

    machineLearning = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run Immich's machine-learning worker (face/object/CLIP search).

        On by default because search is most of why Immich beats a directory of
        JPEGs. It is the expensive half: the worker downloads its models on first
        run and holds them resident.

        Note that this is NOT the biggest consumer — `immich-server` peaks around
        1.4G just importing its geodata on first start, with the worker idle. A
        host that cannot spare that much has no business running Immich at all,
        with or without this. (Learned on kelpy, 4G and no swap: the server
        OOM-looped and took tuwunel and jellyfin down with it.)
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.immich = {
      enable = true;
      inherit (svc) port;
      inherit (cfg) mediaLocation;

      # On the edge, loopback — Caddy is local and nothing else may reach the port.
      # Off the edge, Caddy is on another host and has to come in over tailscale,
      # so bind all interfaces and let the firewall (below) do the limiting. NOT
      # `openFirewall`, which opens every interface including the home LAN.
      host = if offEdge then "0.0.0.0" else "127.0.0.1";
      openFirewall = false;

      machine-learning.enable = cfg.machineLearning;
      database.enable = true;
    };

    services.postgresql.dataDir = lib.mkIf (cfg.databaseDir != "/var/lib/postgresql") cfg.databaseDir;

    networking.firewall.interfaces."tailscale0".allowedTCPPorts = lib.mkIf offEdge [ svc.port ];

    # Gate on the mount that actually holds the data. Without this, systemd's
    # StateDirectory=/CacheDirectory= can create the tree on the tmpfs root before
    # the NVMe lands and the real one is then shadowed — the mount race called out
    # in hosts/rk1/nvme.nix, and the same guard stump.nix carries.
    systemd.services.immich-server.unitConfig.RequiresMountsFor = [ cfg.mediaLocation ];
    systemd.services.postgresql.unitConfig.RequiresMountsFor = [ cfg.databaseDir ];

    # Only meaningful where the data sits under the impermanent root. When it has
    # been moved to a durable NVMe subtree (the rk1 pattern) these paths are
    # already outside /persistent's remit, so the entries would be inert at best.
    environment.persistence."/persistent" =
      lib.mkIf (config.custom.profiles.impermanence.enable && lib.hasPrefix "/var/lib" cfg.mediaLocation)
        {
          directories = [
            cfg.mediaLocation
            cfg.databaseDir
          ];
        };
  };
}
