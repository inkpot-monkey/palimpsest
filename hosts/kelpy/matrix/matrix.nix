{
  config,
  lib,
  self,
  ...
}:
let
  domain = "matrix.palebluebytes.space";

  matrixSettings = config.services.matrix-conduit.settings.global;
  # matrixSubdomain is no longer needed as we run on the root domain
  address = "127.0.0.1";

  # Path to the separate secrets file relative to this nix file
  # nixos/kelpy/matrix/matrix.nix -> ../../../secrets/matrix.yaml
  matrixSecrets = ../../../secrets/matrix.yaml;
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
    # Conduit needs to own this file to read it on startup
    owner = "conduit";
    group = "conduit";
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

    matrixUrl = "http://127.0.0.1:${toString matrixSettings.port}";
    environmentFile = config.sops.templates."jmap-bridge.env".path;

    registration = {
      enable = true;
      asToken = config.sops.placeholder.email_as_token;
      hsToken = config.sops.placeholder.email_hs_token;
      owner = "conduit";
      group = "conduit";
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
      port = 6167;

      trusted_servers = [
        "matrix.org"
        "nixos.org"
        "libera.chat"
      ];

      allow_registration = true;
      # Point to the decrypted secret path
      registration_token_file = config.sops.secrets.registration_token.path;

      # Register the JMAP Bridge (Supported in Conduit)
      app_service_config_files = [ config.services.jmap-bridge.registration.path ];
    };
  };

  # Force static user for Conduit to support sops-nix ownership and valid permissions
  systemd.services.conduit.serviceConfig = {
    DynamicUser = lib.mkForce false;
    User = "conduit";
    Group = "conduit";
  };

  users.users.conduit = {
    isSystemUser = true;
    group = "conduit";
  };
  users.groups.conduit = { };

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

      # Proxy all requests to Conduit
      reverse_proxy /_matrix/* ${address}:${toString matrixSettings.port}
    '';
  };

  environment.persistence."/persistent".directories = [
    "/var/lib/private/conduit"
  ];

  # Enforce secure permissions on /var/lib/private to satisfy DynamicUser requirements
  systemd.tmpfiles.rules = [
    "d /var/lib/private 0700 root root -"
  ];
}
