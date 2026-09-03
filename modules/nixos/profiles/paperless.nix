{
  config,
  lib,
  settings,
  self,
  ...
}:

let
  cfg = config.custom.profiles.paperless;
  inherit (config.networking) domain;
in
{
  options.custom.profiles.paperless = {
    enable = lib.mkEnableOption "Paperless-ngx configuration";
  };

  # NOTE: git-annex backup of the paperless media directory is wired at the host
  # level (see hosts/kelpy/git-annex.nix), not here. A generic profile cannot
  # safely contribute to `services.git-annex.*`: gating that contribution on any
  # config/option value is a self-reference the module system resolves as
  # infinite recursion, and leaving it ungated breaks hosts that never import the
  # git-annex module. The composition layer that imports both modules owns the glue.
  config = lib.mkIf cfg.enable {
    sops.secrets.paperless_secret = {
      sopsFile = self.lib.getSecretPath "profiles/paperless.yaml";
      owner = config.services.paperless.user;
      inherit (config.users.users.${config.services.paperless.user}) group;
    };

    services.paperless = {
      enable = true;
      # NO `package` PIN. This used to take paperless-ngx from nixpkgs-stable, because unstable's
      # pinned ocrmypdf DOWN to ocrmypdf_16 (paperless required <17) and that overridden OCR
      # closure was not on cache.nixos.org, so every re-lock rebuilt ocrmypdf from source.
      #
      # That reason has expired: unstable's paperless-ngx 3.1.1 carries ocrmypdf 17.11.0 with no
      # override, and both are substitutable from cache.nixos.org. Keeping the pin actively broke
      # the host instead — unstable's paperless MODULE reads `cfg.package.tiktokenCacheDir`, a
      # passthru only the 3.x package has, so a stable 2.20.15 package under it fails at eval
      # (`attribute 'tiktokenCacheDir' missing`). Module and package have to come from one pin.
      #
      # NOTE FOR THE NEXT DEPLOY OF THIS HOST: this moves paperless 2.20.15 → 3.1.1, a major
      # upgrade that migrates the document database on first start. Take a backup of
      # /var/lib/paperless before switching kelpy.
      consumptionDirIsPublic = true;
      domain = "paperless.${domain}";
      inherit (settings.services.private.paperless) port;
      passwordFile = config.sops.secrets.paperless_secret.path;
      settings = {
        PAPERLESS_CONSUMER_IGNORE_PATTERN = [
          ".DS_STORE/*"
          "desktop.ini"
        ];
        # PAPERLESS_OCR_LANGUAGE is deliberately NOT set here. Setting it in
        # `settings` makes the NixOS module rebuild tesseract limited to those
        # languages — an uncached closure that re-derives on every deploy. We
        # inject it as a runtime-only env var below instead, so the cached
        # all-language tesseract is used while OCR still runs in eng+spa+cat.
        PAPERLESS_OCR_USER_ARGS = {
          optimize = 1;
          pdfa_image_compression = "lossless";
        };
      };
    };

    # Runtime OCR language, injected outside `services.paperless.settings` so it
    # does not trigger a language-limited tesseract rebuild (see note above).
    systemd.services =
      lib.genAttrs
        [
          "paperless-consumer"
          "paperless-task-queue"
          "paperless-scheduler"
          "paperless-web"
        ]
        (_: {
          environment.PAPERLESS_OCR_LANGUAGE = "eng+spa+cat";
        });

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

    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        config.services.paperless.dataDir
        "/var/lib/redis-paperless"
      ];
    };
  };
}
