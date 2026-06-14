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

  # Appservice registrations from enabled bridges. tuwunel loads these
  # declaratively from `appservice_dir` (unlike Conduit, which required the
  # #admins-room dance). They are passed in as systemd credentials and copied
  # into the appservice dir by `setupAppservices` so the secret tokens never
  # land in a world-readable path.
  bridgeRegistrationCreds =
    lib.optionals config.custom.profiles.matrix.whatsapp.enable [
      "whatsapp-registration.yaml:${config.sops.templates."whatsapp-registration.yaml".path}"
    ]
    ++ lib.optionals config.custom.profiles.matrix.jmap-bridge.enable [
      "jmap-registration.yaml:${config.sops.templates."jmap-registration.yaml".path}"
    ];

  bridgeRestartTriggers =
    lib.optionals config.custom.profiles.matrix.whatsapp.enable [
      config.sops.templates."whatsapp-registration.yaml".path
    ]
    ++ lib.optionals config.custom.profiles.matrix.jmap-bridge.enable [
      config.sops.templates."jmap-registration.yaml".path
    ];

  # Populate tuwunel's appservice_dir from the loaded credentials at start.
  # Runs as the service user (which can read $CREDENTIALS_DIRECTORY and write the
  # RuntimeDirectory), copying only *-registration.yaml so the registration_token
  # credential is excluded from the directory tuwunel parses as appservices.
  tuwunelPreStart = pkgs.writeShellScript "tuwunel-prestart" ''
    set -eu
    # Populate appservice_dir from the loaded credentials (only *-registration.yaml
    # so the registration_token credential is excluded).
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
  adminLocalpart = "inkpotmonkey";
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
      -d "$(${pkgs.jq}/bin/jq -nc --arg u "${adminLocalpart}" --arg p "$pass" \
        '{username:$u,password:$p,inhibit_login:true}')" \
      | ${pkgs.jq}/bin/jq -r '.session // empty')"

    if [ -z "$session" ]; then
      echo "admin account ${adminLocalpart} already exists; nothing to do"
      exit 0
    fi

    # Step 2: complete registration with the token.
    code="$(${pkgs.curl}/bin/curl -s -o /dev/null -w '%{http_code}' -X POST "$url/_matrix/client/v3/register" \
      -H 'content-type: application/json' \
      -d "$(${pkgs.jq}/bin/jq -nc --arg u "${adminLocalpart}" --arg p "$pass" --arg t "$token" --arg s "$session" \
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
        LoadCredential = [
          "registration_token:${config.sops.secrets.registration_token.path}"
        ]
        ++ bridgeRegistrationCreds;
        ExecStartPre = [ tuwunelPreStart ];
      };
      restartTriggers = [
        config.sops.secrets.registration_token.path
      ]
      ++ bridgeRestartTriggers;
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
