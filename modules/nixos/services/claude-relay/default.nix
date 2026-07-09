{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.claude-relay;

  # Idempotently create the relay's bot account via the homeserver's shared
  # registration token (the standard UIA m.login.registration_token flow, also
  # used by tuwunel-register-admin). Runs once before the relay starts so a fresh
  # deploy needs only the password secret in place — no manual account creation.
  registerScript = pkgs.writeShellScript "claude-relay-register" ''
    set -eu
    url=${lib.escapeShellArg cfg.homeserver}
    user=${lib.escapeShellArg cfg.user}
    pass="$(cat "$CREDENTIALS_DIRECTORY/password")"
    token="$(cat "$CREDENTIALS_DIRECTORY/token")"

    for _ in $(seq 1 60); do
      ${pkgs.curl}/bin/curl -sf "$url/_matrix/client/versions" >/dev/null && break
      sleep 2
    done

    # Step 1: initiate registration to obtain a UIA session. If the account
    # already exists the server answers M_USER_IN_USE with no session.
    session="$(${pkgs.curl}/bin/curl -s -X POST "$url/_matrix/client/v3/register" \
      -H 'content-type: application/json' \
      -d "$(${pkgs.jq}/bin/jq -nc --arg u "$user" --arg p "$pass" \
        '{username:$u,password:$p,inhibit_login:true}')" \
      | ${pkgs.jq}/bin/jq -r '.session // empty')"

    if [ -z "$session" ]; then
      echo "relay account $user already exists"
    else
      # Step 2: complete registration with the token.
      code="$(${pkgs.curl}/bin/curl -s -o /dev/null -w '%{http_code}' -X POST "$url/_matrix/client/v3/register" \
        -H 'content-type: application/json' \
        -d "$(${pkgs.jq}/bin/jq -nc --arg u "$user" --arg p "$pass" --arg t "$token" --arg s "$session" \
          '{username:$u,password:$p,inhibit_login:true,auth:{type:"m.login.registration_token",token:$t,session:$s}}')")"
      echo "relay registration HTTP $code"
      [ "$code" = "200" ]
    fi
  '';

  autoRegister = cfg.registrationTokenFile != null;
in
{
  options.services.claude-relay = {
    enable = lib.mkEnableOption "the Claude relay (Matrix <-> persistent claude sessions, ADR-0018)";

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
        ADR-0018 (room ACLs alone do not gate a federated room).
      '';
    };

    operatorPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a file holding the operator (allowedSender) account's password.
        When set, the relay logs in a second, post-nothing client as the operator
        purely to auto-join the rooms the bot invites it to — tuwunel offers no
        server-side force-join, so the invitee must accept, and this does it for
        you. Null (default) leaves rooms invite-only (manual accept).
      '';
    };

    avatarFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to an image (PNG) the relay uploads once and applies as the avatar for
        the bot profile, the "Claude" space, and every relay room (control +
        sessions). Null (default) leaves all avatars unset.
      '';
    };

    claudeCommand = lib.mkOption {
      type = lib.types.str;
      default = "claude";
      description = "Command tmux runs in a session (overridden by tests with a stub).";
    };

    hookPort = lib.mkOption {
      type = lib.types.port;
      default = 8787;
      description = "Loopback port the provisioned claude Stop/Notification hooks POST to.";
    };

    maxSessions = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Concurrency cap: the most simultaneous claude sessions the relay will run.";
    };

    serviceUser = lib.mkOption {
      type = lib.types.str;
      default = "claude-relay";
      description = "System user the relay runs as (set to an existing login to reuse its ~/.claude).";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = cfg.serviceUser;
      defaultText = lib.literalExpression "config.services.claude-relay.serviceUser";
      description = "Primary group of the run-as user.";
    };

    createUser = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to create the run-as system user/group. Disable when reusing an
        existing login (e.g. inkpotmonkey) so the relay's claude sessions inherit
        that account's ~/.claude credentials.
      '';
    };

    registrationTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a file holding the homeserver's shared registration token. When
        set, a `claude-relay-register` oneshot creates the bot account (localpart
        `user`, password from `passwordFile`) via the UIA registration-token flow
        before the relay starts, so deploy needs only the password secret — no
        manual account creation. Null (default) assumes the account already exists.
      '';
    };

    home = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/claude-relay";
      description = ''
        HOME for the run-as user — ~/.claude (claude auth + the relay-provisioned
        Stop/Notification hooks) lives here. Set to the login's home when reusing
        an existing account.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.users = lib.mkIf cfg.createUser {
      ${cfg.serviceUser} = {
        isSystemUser = true;
        inherit (cfg) group home;
        createHome = true;
      };
    };
    users.groups = lib.mkIf cfg.createUser { ${cfg.serviceUser} = { }; };

    # Declaratively create the bot account before the relay logs in (opt-in via
    # registrationTokenFile). A near-verbatim copy of tuwunel-register-admin's
    # UIA token flow; the matrix profile orders it after the admin registration
    # so the admin (not the bot) wins grant_admin_to_first_user.
    systemd.services.claude-relay-register = lib.mkIf autoRegister {
      description = "Register the @${cfg.user} Matrix account (UIA registration-token flow)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      before = [ "claude-relay.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        DynamicUser = true;
        LoadCredential = [
          "token:${toString cfg.registrationTokenFile}"
          "password:${toString cfg.passwordFile}"
        ];
        ExecStart = registerScript;
      };
    };

    systemd.services.claude-relay = {
      description = "Claude relay (Matrix <-> claude sessions)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ] ++ lib.optional autoRegister "claude-relay-register.service";
      wants = [ "network-online.target" ] ++ lib.optional autoRegister "claude-relay-register.service";

      # The relay shells out to tmux (send-keys / session mgmt); the provisioned
      # hook uses curl; a real/stub claude in the session uses jq + a shell.
      path = [
        pkgs.tmux
        pkgs.curl
        pkgs.jq
        pkgs.bash
        pkgs.coreutils
        pkgs.gnugrep
      ];

      environment = {
        HOME = cfg.home;
        # tmux runs a session's command via this shell; the relay's system user has
        # `nologin`, which fails ("Attempted login by UNKNOWN") and kills the pane.
        SHELL = "${pkgs.bash}/bin/bash";
        RELAY_HOMESERVER = cfg.homeserver;
        RELAY_USER = cfg.user;
        RELAY_ALLOWED_SENDER = cfg.allowedSender;
        RELAY_AVATAR = lib.optionalString (cfg.avatarFile != null) (toString cfg.avatarFile);
        RELAY_CLAUDE_CMD = cfg.claudeCommand;
        RELAY_HOOK_PORT = toString cfg.hookPort;
        RELAY_MAX_SESSIONS = toString cfg.maxSessions;
        RUST_LOG = lib.mkDefault "claude_relay=info,matrix_sdk=warn";
      };

      serviceConfig = {
        User = cfg.serviceUser;
        Group = cfg.group;
        StateDirectory = "claude-relay";
        # The bot password arrives as a systemd credential: root reads the (0400,
        # root-owned) sops secret and exposes it in $CREDENTIALS_DIRECTORY readable
        # by the run-as user — so this works even when running as inkpotmonkey,
        # without loosening the secret's permissions.
        LoadCredential = [
          "password:${toString cfg.passwordFile}"
        ]
        ++ lib.optional (
          cfg.operatorPasswordFile != null
        ) "operator_password:${toString cfg.operatorPasswordFile}";
        ExecStart = pkgs.writeShellScript "claude-relay-start" ''
          set -eu
          RELAY_PASSWORD="$(cat "$CREDENTIALS_DIRECTORY/password")"
          export RELAY_PASSWORD
          ${lib.optionalString (cfg.operatorPasswordFile != null) ''
            RELAY_OPERATOR_PASSWORD="$(cat "$CREDENTIALS_DIRECTORY/operator_password")"
            export RELAY_OPERATOR_PASSWORD
          ''}
          exec ${lib.getExe cfg.package}
        '';
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
