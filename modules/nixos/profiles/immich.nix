{
  config,
  lib,
  pkgs,
  self,
  settings,
  ...
}:

let
  cfg = config.custom.profiles.immich;
  # The registry entry is `photos`, not `immich` — the attribute name is the public
  # subdomain, the DNS record and the uptime probe name, so it names the service rather
  # than the software. See the entry's own comment in parts/settings.nix.
  svc = settings.services.private.photos;

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

    provision = {
      enable = lib.mkEnableOption ''
        a post-start oneshot that creates Immich's admin account from sops and mints
        an API key for the CLI importer (immich-provision.py). Immich has no
        declarative path for its first-run account -- a fresh instance sits at
        `isInitialized: false` and refuses everything, and an API key cannot exist
        before the account does. Idempotent and fail-loud, the same shape as
        custom.profiles.homeassistant.provision'';

      adminEmail = lib.mkOption {
        type = lib.types.str;
        default = "admin@${settings.primaryDomain}";
        description = "Email address of the owner account created on first run.";
      };

      adminName = lib.mkOption {
        type = lib.types.str;
        default = "Administrator";
        description = "Display name for that account.";
      };

      apiKeyFile = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/immich-provision/cli-api-key";
        description = ''
          Where to write an API key for the CLI importer, 0600 root.

          Minted only when this file is absent, so re-runs do not accumulate keys on
          the account. Deleting it and re-running the unit issues a fresh one.
        '';
      };
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

    # Both directories must EXIST before their units start, and only systemd's own
    # StateDirectory= would have created them — which it does not once the path is moved
    # off /var/lib. Without this postgres dies at step NAMESPACE with "Failed to set up
    # mount namespacing: /var/cache/postgresql: No such file or directory", restarts five
    # times and hits the start limit; Immich then has no database to reach.
    #
    # A oneshot rather than a tmpfiles rule so it can WAIT for the NVMe mount — tmpfiles
    # runs early and would create these on the tmpfs root, which the real mount then
    # shadows. Same reasoning as stump.nix's stump-library-roots.
    systemd.services.immich-data-dirs = {
      description = "Ensure Immich's media and database directories exist";
      wantedBy = [ "multi-user.target" ];
      before = [
        "immich-server.service"
        "postgresql.service"
      ];
      requiredBy = [
        "immich-server.service"
        "postgresql.service"
      ];
      unitConfig.RequiresMountsFor = [
        cfg.mediaLocation
        cfg.databaseDir
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      # `install -d` is idempotent and sets the same owner/mode the services expect.
      # 0700 on the cluster: it holds Immich's credentials and every asset's metadata.
      script = ''
        install -d -o ${config.services.immich.user} -g ${config.services.immich.group} -m 0750 ${cfg.mediaLocation}
        install -d -o postgres -g postgres -m 0700 ${cfg.databaseDir}
      '';
    };

    # Post-start provisioner (opt-in). Immich has no declarative path for its owner
    # account, so this drives Immich's own signup API — idempotent (a provisioned
    # instance reports isInitialized and is left alone) and fail-loud. Mirrors
    # custom.profiles.homeassistant.provision, down to the LoadCredential handling.
    systemd.services.immich-provision = lib.mkIf cfg.provision.enable {
      description = "Provision Immich's admin account and CLI API key";
      after = [ "immich-server.service" ];
      requires = [ "immich-server.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        IMMICH_URL = "http://127.0.0.1:${toString svc.port}";
        IMMICH_ADMIN_EMAIL = cfg.provision.adminEmail;
        IMMICH_ADMIN_NAME = cfg.provision.adminName;
        IMMICH_API_KEY_FILE = cfg.provision.apiKeyFile;
      };
      # Immich's first start imports its geodata and is slow; retry over a generous
      # window rather than failing a boot race. The window must exceed
      # RestartSec * burst or systemd rate-limits the retries away instantly.
      startLimitIntervalSec = 1800;
      startLimitBurst = 10;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 60;
        # The password lands in a per-service tmpfs, never in argv or a shared env.
        LoadCredential = [ "admin_password:${config.sops.secrets.immich_admin_secret.path}" ];
        ExecStart = pkgs.writeShellScript "immich-provision" ''
          set -euo pipefail
          for _ in $(seq 1 120); do
            code=$(${pkgs.curl}/bin/curl -s -o /dev/null -w '%{http_code}' \
              "$IMMICH_URL/api/server/ping" || true)
            [ "$code" = "200" ] && break
            sleep 5
          done
          exec ${pkgs.python3}/bin/python3 ${./immich-provision.py}
        '';
      };
    };

    # The owner password. Already present in the stash (profiles/media.yaml,
    # `immich_admin_secret`) and until now unused by anything.
    sops.secrets.immich_admin_secret = lib.mkIf cfg.provision.enable {
      sopsFile = self.lib.getSecretFile "media";
    };

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
