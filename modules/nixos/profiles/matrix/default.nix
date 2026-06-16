{
  config,
  lib,
  pkgs,
  self,
  settings,
  ...
}:

let
  cfg = config.custom.profiles.matrix;
  domain = "matrix.palebluebytes.space";
  address = "127.0.0.1";
  matrixPort = settings.services.public.matrix.port;

  matrixSecrets = self.lib.getSecretFile "matrix";

  # Populate tuwunel's appservice_dir from the loaded credentials at start.
  # Runs as the service user (which can read $CREDENTIALS_DIRECTORY and write the
  # RuntimeDirectory), copying only *-registration.yaml so the registration_token
  # credential is excluded from the directory tuwunel parses as appservices.
  tuwunelPreStart = pkgs.writeShellScript "tuwunel-prestart" ''
    set -eu
    install -d -m 0750 /run/tuwunel/appservices
    shopt -s nullglob
    for f in "$CREDENTIALS_DIRECTORY"/*-registration.yaml; do
      install -m 0400 "$f" /run/tuwunel/appservices/
    done
    # tuwunel's local media provider does not create its own root directory, so
    # uploads fail with ENOENT until it exists. Create it under the (persisted)
    # state directory.
    install -d -m 0700 /var/lib/tuwunel/media
  '';

  # Idempotently register the admin Matrix account via the shared registration
  # token (UIA token flow, the same one the aionui notifier self-registers with).
  # Ordered before other account-creating services so `grant_admin_to_first_user`
  # makes this the homeserver admin.
  registerAdmin = pkgs.writeShellScript "tuwunel-register-admin" ''
    set -eu
    url="http://${address}:${toString matrixPort}"
    pass="$(cat "$CREDENTIALS_DIRECTORY/admin_password")"
    token="$(cat "$CREDENTIALS_DIRECTORY/registration_token")"

    for _ in $(seq 1 30); do
      ${pkgs.curl}/bin/curl -sf "$url/_matrix/client/versions" >/dev/null && break
      sleep 2
    done

    # Step 1: initiate registration to obtain a UIA session. If the account
    # already exists the server answers M_USER_IN_USE with no session.
    session="$(${pkgs.curl}/bin/curl -s -X POST "$url/_matrix/client/v3/register" \
      -H 'content-type: application/json' \
      -d "$(${pkgs.jq}/bin/jq -nc --arg u "${cfg.adminLocalpart}" --arg p "$pass" \
        '{username:$u,password:$p,inhibit_login:true}')" \
      | ${pkgs.jq}/bin/jq -r '.session // empty')"

    if [ -z "$session" ]; then
      echo "admin account ${cfg.adminLocalpart} already exists; nothing to do"
      exit 0
    fi

    # Step 2: complete registration with the token.
    code="$(${pkgs.curl}/bin/curl -s -o /dev/null -w '%{http_code}' -X POST "$url/_matrix/client/v3/register" \
      -H 'content-type: application/json' \
      -d "$(${pkgs.jq}/bin/jq -nc --arg u "${cfg.adminLocalpart}" --arg p "$pass" --arg t "$token" --arg s "$session" \
        '{username:$u,password:$p,inhibit_login:true,auth:{type:"m.login.registration_token",token:$t,session:$s}}')")"
    echo "admin registration HTTP $code"
    [ "$code" = "200" ]
  '';
in
{
  imports = [
    ./mautrix-whatsapp.nix
    ./jmap-bridge.nix
  ];

  options.custom.profiles.matrix = {
    enable = lib.mkEnableOption "Matrix homeserver (tuwunel) configuration";

    adminLocalpart = lib.mkOption {
      type = lib.types.str;
      default = "inkpotmonkey";
      description = "Localpart of the Matrix account granted homeserver admin.";
    };

    # Bridge modules contribute their appservice registration here; tuwunel's
    # service wiring (below) consumes the lot generically, so adding a bridge
    # never touches this file. The attr name becomes the credential basename
    # (`<name>-registration.yaml`), which tuwunelPreStart globs into appservice_dir.
    appservices = lib.mkOption {
      internal = true;
      default = { };
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.registrationPath = lib.mkOption {
            type = lib.types.path;
            description = "Path to the bridge's sops-rendered registration.yaml.";
          };
        }
      );
      description = "Appservice registrations contributed by enabled bridge modules.";
    };
  };

  config = lib.mkIf cfg.enable {
    nixpkgs.config.permittedInsecurePackages = [
      "olm-3.2.16"
    ];

    # ----------------------------------------------------------------------------
    # Secret Management (SOPS)
    # ----------------------------------------------------------------------------
    sops.defaultSopsFormat = "yaml";

    sops.secrets.registration_token = {
      sopsFile = matrixSecrets;
    };
    sops.secrets.matrix_admin_password = {
      sopsFile = matrixSecrets;
    };

    # ----------------------------------------------------------------------------
    # tuwunel (Matrix homeserver, conduwuit lineage)
    # ----------------------------------------------------------------------------
    services.matrix-tuwunel = {
      enable = true;
      settings.global = {
        server_name = domain;
        address = [ address ];
        port = [ matrixPort ];

        allow_federation = true;
        trusted_servers = [
          "matrix.org"
          "nixos.org"
          "libera.chat"
        ];

        # Closed registration except via the shared token; the first account
        # created becomes admin.
        allow_registration = true;
        registration_token_file = "/run/credentials/tuwunel.service/registration_token";
        grant_admin_to_first_user = true;

        # Bridges register declaratively from this directory (populated from
        # systemd credentials by setupAppservices below).
        appservice_dir = "/run/tuwunel/appservices/";
      };
    };

    systemd.services.tuwunel = {
      serviceConfig = {
        # tuwunel loads bridge registrations declaratively from `appservice_dir`
        # (unlike Conduit's #admins-room dance). They arrive as systemd credentials
        # and are copied into the dir by tuwunelPreStart, so the secret tokens never
        # land in a world-readable path.
        LoadCredential = [
          "registration_token:${config.sops.secrets.registration_token.path}"
        ]
        ++ lib.mapAttrsToList (name: a: "${name}-registration.yaml:${a.registrationPath}") cfg.appservices;
        ExecStartPre = [ tuwunelPreStart ];
      };
      restartTriggers = [
        config.sops.secrets.registration_token.path
      ]
      ++ lib.mapAttrsToList (_name: a: a.registrationPath) cfg.appservices;
    };

    # Declaratively create the admin account once tuwunel is up.
    systemd.services.tuwunel-register-admin = {
      description = "Register the admin Matrix account on tuwunel";
      after = [ "tuwunel.service" ];
      requires = [ "tuwunel.service" ];
      wantedBy = [ "multi-user.target" ];
      # Register before other account-creating services so this account wins
      # grant_admin_to_first_user.
      before = [ "aionui-notifier.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        DynamicUser = true;
        LoadCredential = [
          "registration_token:${config.sops.secrets.registration_token.path}"
          "admin_password:${config.sops.secrets.matrix_admin_password.path}"
        ];
        ExecStart = registerAdmin;
      };
    };

    # ----------------------------------------------------------------------------
    # Caddy Reverse Proxy
    # ----------------------------------------------------------------------------
    services.caddy.virtualHosts."${domain}" = {
      hostName = domain;
      extraConfig = lib.mkBefore (
        ''
          # Matrix server discovery (Fed)
          handle /.well-known/matrix/server {
            header Content-Type "application/json"
            header Access-Control-Allow-Origin "*"
            respond `{"m.server":"${domain}:443"}`
          }

          # Matrix client discovery
          handle /.well-known/matrix/client {
            header Content-Type "application/json"
            header Access-Control-Allow-Origin "*"
            respond `{"m.homeserver":{"base_url":"https://${domain}"}}`
          }
        ''
        + ''
          import cloudflare_tls
          handle {
            reverse_proxy ${address}:${toString matrixPort}
          }
        ''
      );
    };

    # Enforce secure permissions on /var/lib/private to satisfy DynamicUser
    # requirements (the jmap bridge runs as a DynamicUser).
    systemd.tmpfiles.rules = [
      "z /var/lib/private 0700 root root -"
      "z /persistent/var/lib/private 0700 root root -"
    ];
  };
}
