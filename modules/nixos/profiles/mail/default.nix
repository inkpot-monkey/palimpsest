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
          # The mailbox account's own JMAP/IMAP password. It belongs to THIS
          # profile: the mail server is what the credential authenticates
          # against, and consumers of it (profiles/mail/sieve.nix, and the
          # jmap-bridge under profiles/matrix) all require this profile anyway.
          # It used to be declared only by matrix/jmap-bridge.nix, which made the
          # mail host's access to its own mailbox credential depend on the Matrix
          # profile being enabled. Left root-only (no owner/group) deliberately —
          # every consumer reads it as root or via systemd LoadCredential.
          email_password = {
            sopsFile = self.lib.getSecretPath "profiles/mail.yaml";
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

        # Pin the stalwart-mail uid/gid. These are otherwise auto-allocated and
        # can be reshuffled by a rebuild that adds/removes other system users,
        # which orphans the RocksDB store dir (owned by the old numeric id) and
        # makes Stalwart abort startup with "Store not configured".
        users.users.stalwart-mail.uid = 985;
        users.groups.stalwart-mail.gid = 981;
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
              # Exact key, not `http.*`, and it has to be here at all or the setting above is
              # inert. `config.local-keys` decides which keys are read from THIS file; everything
              # else is read from the database, and a non-local key found in the local config is
              # merely warned about ("Database key defined in local configuration") while the
              # database value continues to win. A bare key with no trailing `*` is an exact match
              # (MatchType::Equal), so this claims `http.url` alone and leaves every other
              # `http.*` key — `http.allowed-endpoint` and friends — editable in the web admin
              # where they already are. Taking the whole prefix would silently drop any of those
              # already set in the database.
              "http.url"
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

            # THE PUBLIC URL STALWART ADVERTISES, and the only key that sets it. Every absolute
            # URL in `/.well-known/oauth-authorization-server`, `/.well-known/openid-configuration`
            # and the JMAP session document is built from this, through `resolve_response_url`.
            #
            # Measured before it was set: every endpoint came back as
            # `http://mail.palebluebytes.space:8082` — plain HTTP, on the internal management port,
            # reachable from nowhere but this host and refused by any OAuth client, since browsers
            # will not complete an OAuth flow over plaintext to a non-localhost origin. The
            # built-in default is `protocol + '://' + config_get('server.hostname') + ':' +
            # local_port`, and because Caddy terminates TLS the listener genuinely sees plain HTTP
            # on 8082 — so the default is wrong in the scheme, the port AND the reachability at
            # once, while looking plausible in the logs.
            #
            # QUOTED ON PURPOSE, and the quotes are load-bearing. `http.url` is an IfBlock, so its
            # value is parsed as an EXPRESSION rather than taken as a literal: `/` is the division
            # operator and `:` is not a legal expression character at all, so an unquoted URL is a
            # parse error. That error is silent in the worst way — `Expression::try_parse` records
            # it and returns None, which falls straight back to the broken default above — so a
            # missing pair of inner quotes would look exactly like this fix not having been
            # applied. The inner single quotes make it a string constant, the same way the
            # built-in default quotes its own `'://'`.
            http.url = "'https://mail.${cfg.domain}'";

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
                  # NO `url` HERE, AND THAT IS THE FIX RATHER THAN AN OMISSION. This listener
                  # carried `url = "https://mail.<domain>"` for a long time and it did nothing:
                  # `server.listener.<id>.url` is not a setting Stalwart has — nothing in 0.15.5
                  # reads a `url` property under `server.listener`, and the shipped
                  # resources/config/config.toml declares none either. It read exactly like the
                  # public-URL setting, which is why the OAuth issuer being wrong went unnoticed
                  # for so long. The real key is `http.url`, set in the settings block below.
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
