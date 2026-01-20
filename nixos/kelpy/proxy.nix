{
  config,
  settings,
  pkgs,
  ...
}:
let
  inherit (config.networking) domain;
  inherit (settings.admin) email;

  # Caddy log dir is "/var/log/caddy"
in
{
  sops = {
    secrets.cloudflare_dns_token = {
      owner = "caddy";
      group = "caddy";
    };
    templates.caddy_env = {
      content = "CLOUDFLARE_API_TOKEN=${config.sops.placeholder.cloudflare_dns_token}";
      owner = "caddy";
      group = "caddy";
    };
  };

  services.caddy = {
    enable = true;
    inherit email;
    package = pkgs.caddy.withPlugins {
      plugins = [ "github.com/caddy-dns/cloudflare@v0.2.1" ];
      hash = "sha256-Zls+5kWd/JSQsmZC4SRQ/WS+pUcRolNaaI7UQoPzJA0=";
    };
    # https://caddyserver.com/docs/caddyfile/options#global-options
    globalConfig = ''
      email ${email}
    '';
    environmentFile = config.sops.templates.caddy_env.path;
  };

  services.caddy.virtualHosts.domain = {
    hostName = domain;
    extraConfig = ''
      respond "Server is up and running!"
              
      handle /echo {
        reverse_proxy 127.0.0.1:9001 {
          header_up Host {host}
          header_up X-Real-IP {remote}
          header_up Connection {>Connection}
          header_up Upgrade {>Upgrade}
        }
      }

    '';

  };

  services.caddy.virtualHosts."mail.palebluebytes.xyz" = {
    extraConfig = ''
      reverse_proxy http://127.0.0.1:8080 {
        header_up Host {host}
        header_up X-Real-IP {remote}
        header_up Connection {>Connection}
        header_up Upgrade {>Upgrade}
      }
    '';
  };

  services.caddy.virtualHosts."mta-sts.palebluebytes.xyz" = {
    extraConfig = ''
      header Content-Type "text/plain"
      respond /.well-known/mta-sts.txt "version: STSv1
      mode: enforce
      mx: mail.palebluebytes.xyz
      max_age: 604800
      " 200
    '';
  };

  # Open firewall ports
  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

  environment.persistence."/persistent".directories = [
    config.services.caddy.dataDir
  ];
}
