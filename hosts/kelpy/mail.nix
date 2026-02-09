{
  config,
  ...
}:
let
  domain = "palebluebytes.xyz";
in
{

  # Define the secret specifically for Stalwart, using the same source key
  sops.secrets = {
    cloudflare_dns_token_stalwart = {
      owner = "stalwart-mail";
      group = "stalwart-mail";
      key = "cloudflare_dns_token";
    };
    stalwart_admin_password = {
      owner = "stalwart-mail";
      group = "stalwart-mail";
    };
  };

  sops.templates.cloudflare_acme_env = {
    content = "CLOUDFLARE_DNS_API_TOKEN=${config.sops.placeholder.cloudflare_dns_token_stalwart}";
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "admin@${domain}";
    certs."mail.${domain}" = {
      dnsProvider = "cloudflare";
      environmentFile = config.sops.templates.cloudflare_acme_env.path;
      group = "stalwart-mail";
    };
  };

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
        hostname = "mail.${domain}";
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
            bind = [ "127.0.0.1:8080" ];
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

      directory."internal" = {
        store = "db";
        type = "internal";
      };

      certificate."default" = {
        cert = "%{file:/var/lib/acme/mail.${domain}/fullchain.pem}%";
        private-key = "%{file:/var/lib/acme/mail.${domain}/key.pem}%";
      };
    };

    # Define credentials (secrets)
    credentials = {
      admin_password = config.sops.secrets.stalwart_admin_password.path;
    };
  };

  services.caddy.virtualHosts."mail.${domain}" = {
    extraConfig = ''
      reverse_proxy http://127.0.0.1:8080 {
        header_up Host {host}
        header_up X-Real-IP {remote}
        header_up Connection {>Connection}
        header_up Upgrade {>Upgrade}
      }
    '';
  };

  services.caddy.virtualHosts."mta-sts.${domain}" = {
    extraConfig = ''
      header Content-Type "text/plain"
      respond /.well-known/mta-sts.txt "version: STSv1
      mode: enforce
      mx: mail.${domain}
      max_age: 604800
      " 200
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
    127.0.0.1 mail.${domain}
  '';
}
