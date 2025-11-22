{
  config,
  lib,
  ...
}:
let
  inherit (lib) mkAfter;

  inherit (config.networking) domain;

  matrixSettings = config.services.matrix-tuwunel.settings.global;
  matrixSubdomain = "matrix.${matrixSettings.server_name}";
  address = "127.0.0.1";
in
{
  # imports = [ ./whatsapp.nix ];

  sops.secrets.matrix_registration_token = {
    owner = config.services.matrix-tuwunel.user;
    group = config.services.matrix-tuwunel.group;
  };

  services.matrix-tuwunel = {
    enable = true;
    # The name of the directory under /var/lib/ where the database will be stored.
    stateDirectory = "tuwunel";

    # These are the matrixSettings at the top
    settings.global = {
      server_name = domain;
      address = [ address ];
      # port is by default set to 6167;

      trusted_servers = [
        "matrix.org"
        "nixos.org"
        "libera.chat"
      ];

      allow_registration = true;
      registration_token_file = config.sops.secrets.matrix_registration_token.path;
    };
  };

  # goes on the root domain
  services.caddy.virtualHosts.domain = {
    hostName = domain;
    extraConfig = mkAfter ''
      # Matrix server discovery with port 443 instead of 8448
      handle /.well-known/matrix/server {
        header Content-Type "application/json"
        header Access-Control-Allow-Origin "*"
        respond `{"m.server":"${matrixSubdomain}:443"}`
      }

      # Matrix client discovery
      handle /.well-known/matrix/client {
        header Content-Type "application/json"
        header Access-Control-Allow-Origin "*"
        respond `{"m.homeserver":{"base_url":"https://${matrixSubdomain}"}}`
      }
    '';
  };

  # Configure Matrix subdomain to proxy to Tuwunel
  services.caddy.virtualHosts.matrix = {
    hostName = matrixSubdomain;
    extraConfig = ''
      # Proxy all requests to Tuwunel
      reverse_proxy /_matrix/* ${address}:${toString matrixSettings.port}
    '';
  };

  environment.persistence."/persistent".directories = [
    "/var/lib/private/${config.services.matrix-tuwunel.stateDirectory}"
  ];
}
