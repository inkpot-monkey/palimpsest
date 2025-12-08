{ config, ... }:
let
  inherit (config.networking) domain;
in
{
  sops.secrets.paperless_secret = {
    owner = config.services.paperless.user;
    group = config.users.users.${config.services.paperless.user}.group;
  };

  services.paperless = {
    enable = true;
    consumptionDirIsPublic = true;
    domain = "paperless.${domain}";
    passwordFile = config.sops.secrets.paperless_secret.path;
    settings = {
      PAPERLESS_CONSUMER_IGNORE_PATTERN = [
        ".DS_STORE/*"
        "desktop.ini"
      ];
      PAPERLESS_OCR_LANGUAGE = "eng+spa+cat";
      PAPERLESS_OCR_USER_ARGS = {
        optimize = 1;
        pdfa_image_compression = "lossless";
      };
    };
  };

  services.caddy.virtualHosts.paperless = {
    hostName = "paperless.${domain}";
    extraConfig = ''
      reverse_proxy http://localhost:${toString config.services.paperless.port} {
        header_up X-Forwarded-Proto https
        header_up X-Forwarded-For {remote_host}
        header_up Host {host}
      }

      # WebSocket support for status endpoint
      handle /ws/status {
        reverse_proxy http://localhost:${toString config.services.paperless.port} {
          header_up Host {host}
          header_up X-Real-IP {remote}
          header_up Connection {>Connection}
          header_up Upgrade {>Upgrade}
        }
      }

      # Allow large file uploads
      request_body {
        max_size 100M
      }

      encode gzip
    '';
  };

  environment.persistence."/persistent".directories = [
    config.services.paperless.mediaDir
    config.services.paperless.dataDir
  ];
}
