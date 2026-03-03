{
  config,
  lib,
  options,
  settings,
  ...
}:
let
  inherit (config.networking) domain;

  gitAnnexDefined = lib.hasAttrByPath [ "services" "git-annex" ] options;
  gitAnnexEnabled = gitAnnexDefined && config.services.git-annex.enable;
in
{
  config = lib.mkMerge [
    {
      sops.secrets.paperless_secret = {
        owner = config.services.paperless.user;
        inherit (config.users.users.${config.services.paperless.user}) group;
      };

      services.paperless = {
        enable = true;
        consumptionDirIsPublic = true;
        domain = "paperless.${domain}";
        port = settings.services.private.paperless.port;
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

      services.caddy.virtualHosts."paperless.${domain}" = {
        extraConfig = lib.mkAfter ''
          # WebSocket support for status endpoint
          handle /ws/status {
            reverse_proxy http://127.0.0.1:${toString settings.services.private.paperless.port} {
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
        "/var/lib/redis-paperless"
      ];
    }
    (lib.optionalAttrs gitAnnexEnabled {
      users.users.${config.services.paperless.user}.extraGroups = [ "git-annex" ];

      services.git-annex.repositories.paperless = {
        path = config.services.paperless.mediaDir;
        description = "paperless";
        inherit (config.services.paperless) user;
        ownerGroup = config.users.users.${config.services.paperless.user}.group;
        assistant = true;
        wanted = "metadata=tag=paperless";
        tags = [ "paperless" ];
        remotes = [
          (
            let
              gateway = config.services.git-annex.repositories.gateway;
            in
            {
              name = "gateway";
              url = gateway.path;
              clusterNode = gateway.clusterName;
              expectedUUID = gateway.uuid;
            }
          )
        ];
      };
    })
  ];
}
