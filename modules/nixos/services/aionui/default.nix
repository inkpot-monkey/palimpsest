{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.aionui;

  # AionUi's backend (aioncore) activates a "managed Node runtime" (and ACP tools)
  # by copying them out of its bundled managed-resources into <data-dir>/runtime.
  # When the bundle lives in the read-only Nix store (0555 dirs), that activation
  # fails with "bundled Node runtime is invalid … Permission denied", and Claude
  # Code (an npm-based ACP agent) cannot launch at all. Fix: stage a *writable*
  # copy of the bundle under the (persisted) data dir and point aioncore at it via
  # --backend-bin. Re-staged only when the package version changes.
  backendDir = "${cfg.dataDir}/backend";
  backendBin = "${backendDir}/linux-x64/aioncore";
  prepareBackend = pkgs.writeShellScript "aionui-prepare-backend" ''
    export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH
    set -eu
    src=${cfg.package}/libexec/aionui-web/bundled-aioncore
    dst=${backendDir}
    ver=${cfg.package.version}
    if [ "$(cat "$dst/.aionui-version" 2>/dev/null || true)" != "$ver" ]; then
      rm -rf "$dst"
      mkdir -p "$dst"
      cp -a --reflink=auto "$src/." "$dst/"
      chmod -R u+w "$dst"
      printf '%s' "$ver" > "$dst/.aionui-version"
    fi
  '';
in
{
  options.services.aionui = {
    enable = lib.mkEnableOption "AionUi WebUI server (browser frontend for Claude Code & other agents)";

    package = lib.mkPackageOption pkgs "aionui" { };

    port = lib.mkOption {
      type = lib.types.port;
      default = 25808;
      description = "TCP port the AionUi web-host listens on (bound to 127.0.0.1 unless allowRemote).";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/aionui";
      description = "Directory for AionUi's SQLite database, config, logs and skills.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "aionui";
      description = ''
        User to run AionUi as. To let AionUi reuse an existing Claude Code login
        (~/.claude) and reach the user's project checkouts, set this to that login
        account and set {option}`createUser` to false.
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = cfg.user;
      description = "Group to run AionUi as.";
    };

    createUser = lib.mkOption {
      type = lib.types.bool;
      default = cfg.user == "aionui";
      description = "Whether to create the service user/group. Disable when reusing an existing login account.";
    };

    agentPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.git pkgs.nodejs ]";
      description = ''
        Packages prepended to the service PATH so the AionUi backend can detect and
        spawn coding agents (e.g. the `claude` CLI for Claude Code), plus their
        runtime tools (git, node).
      '';
    };

    allowRemote = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Bind the web-host on 0.0.0.0 instead of 127.0.0.1. Leave false and reach it
        through a reverse proxy. NOTE: AionUi's web-host launches its backend in
        "local" mode, which does NOT enforce the admin password — so the only access
        control is the network boundary. Do not expose this to untrusted networks.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open {option}`port` in the firewall.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Optional environment file (e.g. a sops secret) sourced by the service.";
      example = "/run/secrets/aionui-env";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users = lib.mkIf cfg.createUser {
      ${cfg.user} = {
        isSystemUser = true;
        inherit (cfg) group;
        home = cfg.dataDir;
        createHome = false;
        description = "AionUi service user";
      };
    };
    users.groups = lib.mkIf cfg.createUser { ${cfg.group} = { }; };

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0750 ${cfg.user} ${cfg.group} - -"
    ];

    systemd.services.aionui = {
      description = "AionUi WebUI server";
      documentation = [ "https://github.com/iOfficeAI/AionUi" ];
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "local-fs.target"
      ];

      # On PATH so the backend (aioncore) can discover/spawn coding agents.
      path = cfg.agentPackages;

      environment = {
        AIONUI_PORT = toString cfg.port;
        AIONUI_DATA_DIR = cfg.dataDir;
        # Run with the account's home so the bundled Claude adapter finds the
        # user's `claude login` credentials (~/.claude) and project checkouts.
        HOME = config.users.users.${cfg.user}.home or cfg.dataDir;
      };

      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        # Stage the writable backend copy before launch (see backendDir comment).
        ExecStartPre = prepareBackend;
        ExecStart = lib.concatStringsSep " " (
          [
            (lib.getExe cfg.package)
            "start"
            "--no-open"
            "--port"
            (toString cfg.port)
            "--data-dir"
            cfg.dataDir
            "--backend-bin"
            backendBin
          ]
          ++ lib.optional cfg.allowRemote "--remote"
        );
        Restart = "on-failure";
        RestartSec = "5s";
        # First launch stages the backend copy (~hundreds of MB), initialises the
        # SQLite DB and seeds the admin user; give it generous headroom.
        TimeoutStartSec = "600s";

        EnvironmentFile = lib.mkIf (cfg.environmentFile != null) cfg.environmentFile;

        # Light hardening only: the backend deliberately runs agents against the
        # user's home (~/.claude, ~/code), so ProtectHome/strict ProtectSystem
        # would break it.
        NoNewPrivileges = true;
        PrivateTmp = true;
      };
    };

    networking.firewall.allowedTCPPorts = lib.optional cfg.openFirewall cfg.port;
  };
}
