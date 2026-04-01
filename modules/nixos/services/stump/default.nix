{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.stump;
in
{
  options.services.stump = {
    enable = lib.mkEnableOption "Stump media server";

    package = lib.mkPackageOption pkgs "stump" { };

    port = lib.mkOption {
      type = lib.types.port;
      default = 10801;
      description = "TCP port Stump listens on.";
      example = 10801;
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/stump";
      description = "Directory where Stump stores its config, SQLite database, and thumbnails.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "stump";
      description = "User account under which Stump runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "stump";
      description = "Group under which Stump runs.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the firewall port for Stump's HTTP server.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to an environment file containing sensitive configuration variables,
        e.g. from sops-nix. Each line should be of the form KEY=value.

        Useful variables include:
          STUMP_OIDC_CLIENT_ID
          STUMP_OIDC_CLIENT_SECRET
          STUMP_OIDC_ISSUER_URL
      '';
      example = "/run/secrets/stump-env";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      inherit (cfg) group;
      description = "Stump media server service user";
      home = cfg.dataDir;
      createHome = false;
    };

    users.groups.${cfg.group} = { };

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0750 ${cfg.user} ${cfg.group} - -"
    ];

    systemd.services.stump = {
      description = "Stump media server";
      documentation = [ "https://stumpapp.dev/guides" ];
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "local-fs.target"
      ];

      environment = {
        STUMP_CONFIG_DIR = cfg.dataDir;
        STUMP_PORT = toString cfg.port;
        STUMP_CLIENT_DIR = "${cfg.package}/share/stump/web";
        STUMP_PROFILE = "release";
      };

      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        ExecStart = lib.getExe cfg.package;
        Restart = "on-failure";
        RestartSec = "5s";

        # Load secrets from an optional environment file (e.g. sops secret)
        EnvironmentFile = lib.mkIf (cfg.environmentFile != null) cfg.environmentFile;

        # Hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        ProtectKernelModules = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        # Allow read-write access to the data directory only
        ReadWritePaths = [ cfg.dataDir ];
        # Stump serves static files from its nix store path – needs read access
        ReadOnlyPaths = [ "${cfg.package}/share/stump/web" ];
      };
    };

    networking.firewall.allowedTCPPorts = lib.optional cfg.openFirewall cfg.port;
  };
}
