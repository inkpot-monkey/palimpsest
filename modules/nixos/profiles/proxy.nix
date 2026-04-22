{
  config,
  lib,
  settings,
  pkgs,
  inputs,
  ...
}:

let
  cfg = config.custom.profiles.proxy;
  inherit (config.networking) domain;
  inherit (settings.admin) email;
in
{
  options.custom.profiles.proxy = {
    enable = lib.mkEnableOption "Caddy reverse proxy configuration";
  };

  config = lib.mkIf cfg.enable {
    sops = {
      secrets.cloudflare_dns_token = {
        sopsFile = inputs.secrets + "/profiles/networking.yaml";
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
        hash = "sha256-B5xXld1+IRUAQHm8zkHFqvRp8cqnervVL6XEos5VNkc=";
      };
      globalConfig = "";
      extraConfig = ''
        (internal_only) {
          @not_internal {
            not remote_ip 100.64.0.0/10 127.0.0.1 ::1 fd7a:115c:a1e0::/48
          }
          abort @not_internal
        }

        (cloudflare_tls) {
          tls {
            dns cloudflare {env.CLOUDFLARE_API_TOKEN}
          }
        }
      '';
      environmentFile = config.sops.templates.caddy_env.path;

      virtualHosts =
        let
          allServices =
            (lib.mapAttrs (_: svc: svc // { isPublic = true; }) settings.services.public)
            // (lib.mapAttrs (_: svc: svc // { isPublic = false; }) settings.services.private);
          hostServices = lib.filterAttrs (_: svc: svc.node == config.networking.hostName) allServices;
        in
        lib.mkMerge [
          (lib.mapAttrs' (
            name: svc:
            lib.nameValuePair "${name}.${config.networking.domain}" {
              extraConfig = ''
                ${lib.optionalString (!svc.isPublic) "import internal_only"}
                import cloudflare_tls
                reverse_proxy 127.0.0.1:${toString svc.port}
              '';
            }
          ) hostServices)
          {
            "${domain}" = {
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
          }
        ];
    };

    # Open firewall ports
    networking.firewall.allowedTCPPorts = [
      80
      443
    ];

    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        config.services.caddy.dataDir
      ];
    };
  };
}
