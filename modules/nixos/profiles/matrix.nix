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

  # matrixSubdomain is no longer needed as we run on the root domain
  address = "127.0.0.1";

  # Path to the separate secrets file relative to this nix file
  # Updated to use self for absolute path
  matrixSecrets = self.lib.getSecretFile "matrix";
in
{
  imports = [ self.nixosModules.jmap-bridge ];

  options.custom.profiles.matrix = {
    enable = lib.mkEnableOption "Matrix (Conduit) configuration";
  };

  config = lib.mkIf cfg.enable {
    # ----------------------------------------------------------------------------
    # Secret Management (SOPS)
    # ----------------------------------------------------------------------------
    sops.defaultSopsFormat = "yaml";

    # Define secrets from secrets/matrix.yaml
    sops.secrets.email_as_token = {
      sopsFile = matrixSecrets;
    };
    sops.secrets.email_hs_token = {
      sopsFile = matrixSecrets;
    };
    sops.secrets.email_password = {
      sopsFile = matrixSecrets;
    };

    sops.secrets.registration_token = {
      sopsFile = matrixSecrets;
    };

    # ----------------------------------------------------------------------------
    # JMAP Bridge Configuration
    # ----------------------------------------------------------------------------

    # Template for environment file (populated with decrypted secrets)
    sops.templates."jmap-bridge.env" = {
      content = ''
        MATRIX_AS_TOKEN=${config.sops.placeholder.email_as_token}
        JMAP_TOKEN=${config.sops.placeholder.email_password}
      '';
    };

    services.jmap-bridge = {
      enable = true;
      username = "test";

      # Use internal listener directly to avoid public/private port confusion
      url = "http://127.0.0.1:8080/jmap/session";

      matrixUrl = "http://127.0.0.1:${toString settings.services.public.matrix.port}";
      environmentFile = config.sops.templates."jmap-bridge.env".path;

      registration = {
        enable = true;
        asToken = config.sops.placeholder.email_as_token;
        hsToken = config.sops.placeholder.email_hs_token;
      };
    };

    # ----------------------------------------------------------------------------
    # Matrix Tuwunel Configuration
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
        # Point to the decrypted secret path via systemd credentials
        registration_token_file = "/run/credentials/conduit.service/registration_token";

        # Register the JMAP Bridge (Supported in Conduit)
        app_service_config_files = [ "/run/credentials/conduit.service/jmap-bridge-registration.yaml" ];
      };
    };

    systemd.services.conduit.serviceConfig.LoadCredential = [
      "registration_token:${config.sops.secrets.registration_token.path}"
      "jmap-bridge-registration.yaml:${config.services.jmap-bridge.registration.path}"
    ];

    # ----------------------------------------------------------------------------
    # Caddy Reverse Proxy
    # ----------------------------------------------------------------------------

    # Matrix Server Virtual Host (Handles Federation, Client API, and Discovery)
    services.caddy.virtualHosts."${domain}" = {
      hostName = domain;
      extraConfig = lib.mkAfter ''
        # Matrix server discovery (Fed) - Pointing to itself for correctness
        handle /.well-known/matrix/server {
          header Content-Type "application/json"
          header Access-Control-Allow-Origin "*"
          respond `{"m.server":"${domain}:443"}`
        }

        # Matrix client discovery - Pointing to itself
        handle /.well-known/matrix/client {
          header Content-Type "application/json"
          header Access-Control-Allow-Origin "*"
          respond `{"m.homeserver":{"base_url":"https://${domain}"}}`
        }
      '';
    };

    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        "/var/lib/jmap-bridge"
      ];
    };

    # Enforce secure permissions on /var/lib/private to satisfy DynamicUser requirements
    systemd.tmpfiles.rules = [
      "z /var/lib/private 0700 root root -"
      "z /persistent/var/lib/private 0700 root root -"
    ];
  };
}
