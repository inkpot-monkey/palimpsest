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
  setupAppservices = pkgs.writeShellScript "tuwunel-appservices" ''
    set -eu
    install -d -m 0750 /run/tuwunel/appservices
    shopt -s nullglob
    for f in "$CREDENTIALS_DIRECTORY"/*-registration.yaml; do
      install -m 0400 "$f" /run/tuwunel/appservices/
    done
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
        ExecStartPre = [ setupAppservices ];
      };
      restartTriggers = [
        config.sops.secrets.registration_token.path
      ]
      ++ bridgeRestartTriggers;
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
