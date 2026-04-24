{
  config,
  options,
  lib,
  settings,
  inputs,
  ...
}:

let
  cfg = config.custom.profiles.mail;
in
{
  options.custom.profiles.mail = {
    enable = lib.mkEnableOption "mail server configuration (Stalwart)";
    domain = lib.mkOption {
      type = lib.types.str;
      example = "example.com";
      description = "The domain to use for the mail server.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        sops.secrets = {
          cloudflare_dns_token_stalwart = {
            sopsFile = inputs.secrets + "/profiles/mail.yaml";
            owner = "stalwart-mail";
            group = "stalwart-mail";
            key = "cloudflare_dns_token";
          };
          stalwart_admin_password = {
            sopsFile = inputs.secrets + "/profiles/mail.yaml";
            owner = "stalwart-mail";
            group = "stalwart-mail";
          };
        };

        sops.templates.cloudflare_acme_env = {
          content = "CLOUDFLARE_DNS_API_TOKEN=${config.sops.placeholder.cloudflare_dns_token_stalwart}";
        };

        security.acme = {
          acceptTerms = true;
          defaults.email = "admin@${cfg.domain}";
          certs."mail.${cfg.domain}" = {
            dnsProvider = "cloudflare";
            environmentFile = config.sops.templates.cloudflare_acme_env.path;
            group = "stalwart-mail";
          };
        };

        environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
          directories = [
            "/var/lib/acme"
            "/var/lib/stalwart-mail"
          ];
        };

        users.groups.stalwart-mail.members = [ "caddy" ];
        services.caddy.virtualHosts."mta-sts.${cfg.domain}" = {
          extraConfig = ''
            header Content-Type "text/plain"
            respond /.well-known/mta-sts.txt "version: STSv1
            mode: enforce
            mx: mail.${cfg.domain}
            max_age: 15778800
            " 200
          '';
        };

        # HTTPS Proxy for Stalwart Web Admin and JMAP
        services.caddy.virtualHosts."mail.${cfg.domain}" = {
          useACMEHost = "mail.${cfg.domain}";
          extraConfig = ''
            reverse_proxy 127.0.0.1:${toString settings.services.public.mail.port}
          '';
        };

        # Mail Client Autodiscovery/Autoconfig
        services.caddy.virtualHosts."autoconfig.${cfg.domain}" = {
          extraConfig = ''
            header Content-Type "application/xml"
            respond /mail/config-v1.1.xml "<?xml version='1.0' encoding='UTF-8'?><clientConfig version='1.1'><emailProvider id='${cfg.domain}'><domain>${cfg.domain}</domain><displayName>Stalwart Mail</displayName><displayShortName>Stalwart</displayShortName><incomingServer type='imap'><hostname>mail.${cfg.domain}</hostname><port>993</port><socketType>SSL</socketType><authentication>password-cleartext</authentication><username>%EMAILADDRESS%</username></incomingServer><outgoingServer type='smtp'><hostname>mail.${cfg.domain}</hostname><port>465</port><socketType>SSL</socketType><authentication>password-cleartext</authentication><username>%EMAILADDRESS%</username></outgoingServer></emailProvider></clientConfig>" 200
          '';
        };

        services.caddy.virtualHosts."autodiscover.${cfg.domain}" = {
          extraConfig = ''
            header Content-Type "text/xml"
            @post {
                method POST
                path /autodiscover/autodiscover.xml
            }
            respond @post "<?xml version='1.0' encoding='utf-8'?><Autodiscover xmlns='http://schemas.microsoft.com/exchange/autodiscover/responseschema/2006'><Response xmlns='http://schemas.microsoft.com/exchange/autodiscover/outlook/responseschema/2006a'><Account><AccountType>email</AccountType><Action>settings</Action><Protocol><Type>IMAP</Type><Server>mail.${cfg.domain}</Server><Port>993</Port><SSL>on</SSL><AuthRequired>on</AuthRequired><LoginName>%EmailAddress%</LoginName></Protocol><Protocol><Type>SMTP</Type><Server>mail.${cfg.domain}</Server><Port>465</Port><SSL>on</SSL><AuthRequired>on</AuthRequired><LoginName>%EmailAddress%</LoginName></Protocol></Account></Response></Autodiscover>" 200
          '';
        };

        networking.firewall.allowedTCPPorts = [
          25 # SMTP
          465 # SMTPS
          587 # Submission
          993 # IMAPS
        ];

        # Map the mail domain to localhost internally so that:
        # 1. The bridge can access http://mail.palebluebytes.xyz:8080 (advertised by Stalwart)
        # 2. We don't hit the public firewall for internal traffic
        networking.extraHosts = ''
          127.0.0.1 mail.${cfg.domain}
        '';
      }
      (lib.optionalAttrs (options.services ? stalwart) {
        services.stalwart = {
          enable = true;
          settings = {
            config.local-keys = [
              "store.*"
              "directory.*"
              "tracer.*"
              "!server.blocked-ip.*"
              "!server.allowed-ip.*"
              "server.*"
              "cluster.*"
              "config.local-keys.*"
              "storage.data"
              "storage.blob"
              "storage.lookup"
              "storage.fts"
              "storage.directory"
              "certificate.*"
              "authentication.*"
              "resolver.*" # Avoid warnings for default resolver settings
              "spam-filter.*" # Avoid warnings for default spam settings
              "webadmin.*"
            ];
            authentication.fallback-admin = {
              user = "admin";
              secret = "%{file:/run/credentials/stalwart-mail.service/admin_password}%";
            };
            authentication.mechanisms = [
              "plain"
              "login"
            ];
            authentication.directory = "internal"; # Use the internal directory (defined below)

            server = {
              hostname = "mail.${cfg.domain}";
              tls = {
                enable = true;
                implicit = false;
              };
              listener = {
                "smtp" = {
                  bind = [ "[::]:25" ];
                  protocol = "smtp";
                };
                "submission" = {
                  bind = [ "[::]:587" ];
                  protocol = "smtp";
                };
                "submissions" = {
                  bind = [ "[::]:465" ];
                  protocol = "smtp";
                  tls.implicit = true;
                  tls.certificate = "default";
                };
                "imaps" = {
                  bind = [ "[::]:993" ];
                  protocol = "imap";
                  tls.implicit = true;
                  tls.certificate = "default";
                };
                "management" = {
                  bind = [ "127.0.0.1:${toString settings.services.public.mail.port}" ];
                  protocol = "http";
                  url = "https://mail.${cfg.domain}";
                };
                "jmap" = {
                  bind = [ "127.0.0.1:8081" ]; # Internal JMAP port
                  protocol = "jmap";
                };
              };
            };

            storage = {
              directory = "internal";
              data = "db";
              blob = "db";
              lookup = "db";
              fts = "db";
            };

            storage.db = {
              type = "rocksdb";
              path = "/var/lib/stalwart-mail/db";
            };

            directory."internal" = {
              store = "db";
              type = "internal";
            };

            certificate."default" = {
              cert = "%{file:/var/lib/acme/mail.${cfg.domain}/fullchain.pem}%";
              private-key = "%{file:/var/lib/acme/mail.${cfg.domain}/key.pem}%";
            };
          };

          # Define credentials (secrets)
          credentials = {
            admin_password = config.sops.secrets.stalwart_admin_password.path;
          };
        };
      })
    ]
  );
}
