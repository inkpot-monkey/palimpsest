{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.claude-relay;
in
{
  options.services.claude-relay = {
    enable = lib.mkEnableOption "the Claude relay (Matrix <-> persistent claude sessions, ADR-0025)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = "The claude-relay package.";
    };

    homeserver = lib.mkOption {
      type = lib.types.str;
      example = "http://127.0.0.1:6167";
      description = "Base URL of the Matrix homeserver the relay logs in to.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "claude-relay";
      description = "Localpart of the relay bot account.";
    };

    passwordFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to a file containing the relay bot account's password. Read at
        service start; never embedded in the store.
      '';
    };

    allowedSender = lib.mkOption {
      type = lib.types.str;
      example = "@thomas:palebluebytes.space";
      description = ''
        The ONLY sender MXID the relay will act on. Enforced in-process per
        ADR-0025 (room ACLs alone do not gate a federated room).
      '';
    };

    serviceUser = lib.mkOption {
      type = lib.types.str;
      default = "claude-relay";
      description = "System user the relay runs as.";
      internal = true;
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.serviceUser} = {
      isSystemUser = true;
      group = cfg.serviceUser;
      home = "/var/lib/claude-relay";
      createHome = true;
    };
    users.groups.${cfg.serviceUser} = { };

    systemd.services.claude-relay = {
      description = "Claude relay (Matrix <-> claude sessions)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = {
        RELAY_HOMESERVER = cfg.homeserver;
        RELAY_USER = cfg.user;
        RELAY_ALLOWED_SENDER = cfg.allowedSender;
        RUST_LOG = lib.mkDefault "claude_relay=info,matrix_sdk=warn";
      };

      serviceConfig = {
        User = cfg.serviceUser;
        Group = cfg.serviceUser;
        StateDirectory = "claude-relay";
        # Read the bot password out of its file into the env, then exec the relay.
        ExecStart = pkgs.writeShellScript "claude-relay-start" ''
          set -eu
          RELAY_PASSWORD="$(cat ${lib.escapeShellArg (toString cfg.passwordFile)})"
          export RELAY_PASSWORD
          exec ${lib.getExe cfg.package}
        '';
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
