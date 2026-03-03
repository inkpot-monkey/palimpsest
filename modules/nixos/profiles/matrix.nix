{
  config,
  lib,
  self,
  settings,
  ...
}:
let
  domain = "matrix.palebluebytes.space";

  # matrixSubdomain is no longer needed as we run on the root domain
  address = "127.0.0.1";

  # Path to the separate secrets file relative to this nix file
  # Updated to use self for absolute path
  matrixSecrets = self + "/secrets/matrix.yaml";
in
{
  imports = [ self.nixosModules.jmap-bridge ];

  # ----------------------------------------------------------------------------
  # Secret Management (SOPS)
  # ----------------------------------------------------------------------------
  sops.defaultSopsFormat = "yaml";

  # Define secrets from secrets/matrix.yaml
  # Structure in file is flat:
  # registration_token
  # email_as_token
  # email_hs_token
  # email_password

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
  # Note: The bridge expects env vars, we map them from the decrypted secrets here.
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
    # Stalwart listens on 127.0.0.1:8080
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
    # stateDirectory = "conduit"; # Conduit module usually handles this

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

  # Matrix Conduit handles its state directory automatically when DynamicUser is enabled

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

  # Persistence is now handled at the /var/lib/private level in impermanence.nix
  environment.persistence."/persistent".directories = [
    "/var/lib/jmap-bridge"
  ];

  # Enforce secure permissions on /var/lib/private to satisfy DynamicUser requirements
  # We use 'z' to recursively fix permissions on both ephemeral and persistent paths
  systemd.tmpfiles.rules = [
    "z /var/lib/private 0700 root root -"
    "z /persistent/var/lib/private 0700 root root -"
  ];
}
