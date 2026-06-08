{
  config,
  options,
  lib,
  self,
  ...
}:

let
  cfg = config.custom.profiles.mail;
  managementPort = 8082;
in
{
  options.custom.profiles.mail = {
    enable = lib.mkEnableOption "mail server configuration (Stalwart)";
    domain = lib.mkOption {
      type = lib.types.str;
      example = "example.com";
      description = "The primary domain to use for the mail server.";
    };
    extraDomains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "example2.com" ];
      description = "Extra domains to handle email for.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        sops.secrets = {
          cloudflare_dns_token_stalwart = {
            sopsFile = self.lib.getSecretPath "profiles/mail.yaml";
            owner = "stalwart-mail";
            group = "stalwart-mail";
            key = "cloudflare_dns_token";
          };
          stalwart_admin_password = {
            sopsFile = self.lib.getSecretPath "profiles/mail.yaml";
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

        systemd.services.stalwart.serviceConfig.LoadCredential = [
          "admin_password:${config.sops.secrets.stalwart_admin_password.path}"
        ];
        services.caddy.virtualHosts =
          let
            allDomains = [ cfg.domain ] ++ cfg.extraDomains;
            mkMtaSts = dom: {
              "mta-sts.${dom}" = {
                extraConfig = ''
                  import cloudflare_tls
                  header Content-Type "text/plain"
                  respond /.well-known/mta-sts.txt "version: STSv1
                  mode: enforce
                  mx: mail.${cfg.domain}
                  max_age: 15778800
                  " 200
                '';
              };
            };
            mkAutoconfig = dom: {
              "autoconfig.${dom}" = {
                extraConfig = ''
                  import cloudflare_tls
                  header Content-Type "application/xml"
                  respond /mail/config-v1.1.xml "<?xml version='1.0' encoding='UTF-8'?><clientConfig version='1.1'><emailProvider id='${dom}'><domain>${dom}</domain><displayName>Stalwart Mail</displayName><displayShortName>Stalwart</displayShortName><incomingServer type='imap'><hostname>mail.${cfg.domain}</hostname><port>993</port><socketType>SSL</socketType><authentication>password-cleartext</authentication><username>%EMAILADDRESS%</username></incomingServer><outgoingServer type='smtp'><hostname>mail.${cfg.domain}</hostname><port>465</port><socketType>SSL</socketType><authentication>password-cleartext</authentication><username>%EMAILADDRESS%</username></outgoingServer></emailProvider></clientConfig>" 200
                '';
              };
            };
            mkAutodiscover = dom: {
              "autodiscover.${dom}" = {
                extraConfig = ''
                  import cloudflare_tls
                  header Content-Type "text/xml"
                  @post {
                      method POST
                      path /autodiscover/autodiscover.xml
                  }
                  respond @post "<?xml version='1.0' encoding='utf-8'?><Autodiscover xmlns='http://schemas.microsoft.com/exchange/autodiscover/responseschema/2006'><Response xmlns='http://schemas.microsoft.com/exchange/autodiscover/outlook/responseschema/2006a'><Account><AccountType>email</AccountType><Action>settings</Action><Protocol><Type>IMAP</Type><Server>mail.${cfg.domain}</Server><Port>993</Port><SSL>on</SSL><AuthRequired>on</AuthRequired><LoginName>%EmailAddress%</LoginName></Protocol><Protocol><Type>SMTP</Type><Server>mail.${cfg.domain}</Server><Port>465</Port><SSL>on</SSL><AuthRequired>on</AuthRequired><LoginName>%EmailAddress%</LoginName></Protocol></Account></Response></Autodiscover>" 200
                '';
              };
            };
          in
          lib.mkMerge (
            [
              {
                "mail.${cfg.domain}" = {
                  extraConfig = ''
                    import cloudflare_tls
                    @jmap {
                        path /jmap* /.well-known/jmap*
                    }
                    reverse_proxy @jmap 127.0.0.1:8081
                    reverse_proxy 127.0.0.1:${toString managementPort}
                  '';
                };
              }
            ]
            ++ (map mkMtaSts allDomains)
            ++ (map mkAutoconfig allDomains)
            ++ (map mkAutodiscover allDomains)
          );

        networking.firewall.allowedTCPPorts = [
          25 # SMTP
          465 # SMTPS
          587 # Submission
          993 # IMAPS
        ];

        # Map the mail domain to localhost internally so that:
        # 1. The bridge can access http://mail.palebluebytes.space:8082 (advertised by Stalwart)
        # 2. We don't hit the public firewall for internal traffic
        networking.extraHosts = ''
          127.0.0.1 mail.${cfg.domain}
        '';
      }
      (lib.optionalAttrs (options.services ? stalwart) {
        services.stalwart = {
          enable = true;
          inherit (config.system) stateVersion;
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
              secret = "%{file:/run/credentials/stalwart.service/admin_password}%";
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
                  bind = [ "127.0.0.1:${toString managementPort}" ];
                  protocol = "http";
                  url = "https://mail.${cfg.domain}";
                };
                "jmap" = {
                  bind = [ "127.0.0.1:8081" ]; # Internal JMAP port
                  protocol = "http";
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

            spam-filter = {
              enable = true;
              classifier = {
                model = "ftrl-fh";
              };
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
