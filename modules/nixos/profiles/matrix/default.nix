{
  config,
  lib,
  self,
  settings,
  ...
}:

let
  cfg = config.custom.profiles.matrix;
  domain = "matrix.palebluebytes.space";
  address = "127.0.0.1";

  matrixSecrets = self.lib.getSecretFile "matrix";

  # Collect appservice registrations from enabled bridges
  appServiceRegistrations =
    lib.optionals config.custom.profiles.matrix.whatsapp.enable [
      "/run/credentials/conduit.service/whatsapp-registration.yaml"
    ]
    ++ lib.optionals config.custom.profiles.matrix.jmap-bridge.enable [
      "/run/credentials/conduit.service/jmap-bridge-registration.yaml"
    ];

  # Collect LoadCredential entries from enabled bridges
  bridgeCredentials =
    lib.optionals config.custom.profiles.matrix.whatsapp.enable [
      "whatsapp-registration.yaml:${config.sops.templates."whatsapp-registration.yaml".path}"
    ]
    ++ lib.optionals config.custom.profiles.matrix.jmap-bridge.enable [
      "jmap-bridge-registration.yaml:${config.sops.templates."jmap-registration.yaml".path}"
    ];
in
{
  imports = [
    ./mautrix-whatsapp.nix
    ./jmap-bridge.nix
  ];

  options.custom.profiles.matrix = {
    enable = lib.mkEnableOption "Matrix (Conduit) configuration";
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
    # Matrix Conduit (Homeserver)
    # ----------------------------------------------------------------------------
    services.matrix-conduit = {
      enable = true;
      settings.global = {
        server_name = domain;
        inherit address;
        inherit (settings.services.public.matrix) port;

        trusted_servers = [
          "matrix.org"
          "nixos.org"
          "libera.chat"
        ];

        allow_registration = true;
        registration_token_file = "/run/credentials/conduit.service/registration_token";

        # NOTE: Conduit does NOT support app_service_config_files. Appservices (bridges)
        # must be registered and updated dynamically in the homeserver's #admins room.
        # This parameter is kept here only for reference, or can be ignored.
        app_service_config_files = appServiceRegistrations;
      };
    };

    systemd.services.conduit.serviceConfig.LoadCredential = [
      "registration_token:${config.sops.secrets.registration_token.path}"
    ]
    ++ bridgeCredentials;

    systemd.services.conduit.restartTriggers = [
      config.sops.secrets.registration_token.path
    ]
    ++ lib.optionals config.custom.profiles.matrix.whatsapp.enable [
      config.sops.templates."whatsapp-registration.yaml".path
    ]
    ++ lib.optionals config.custom.profiles.matrix.jmap-bridge.enable [
      config.sops.templates."jmap-registration.yaml".path
    ];

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
            reverse_proxy 127.0.0.1:${toString settings.services.public.matrix.port}
          }
        ''
      );
    };

    # Enforce secure permissions on /var/lib/private to satisfy DynamicUser requirements
    systemd.tmpfiles.rules = [
      "z /var/lib/private 0700 root root -"
      "z /persistent/var/lib/private 0700 root root -"
    ];
  };
}
