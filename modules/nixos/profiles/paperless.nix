{
  config,
  lib,
  pkgs,
  settings,
  self,
  ...
}:

let
  cfg = config.custom.profiles.paperless;
  inherit (config.networking) domain;

  alertPost = import ../../shared/alert-post.nix { inherit lib pkgs; };

  inherit (config.services.paperless) dataDir;
in
{
  options.custom.profiles.paperless = {
    enable = lib.mkEnableOption "Paperless-ngx configuration";

    dump = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Take a nightly `VACUUM INTO` dump of the document database beside the live one.

          On by default, because a host that keeps scanned paper and backs up its data
          directory would otherwise be shipping the originals with an index that may not open —
          see modules/nixos/profiles/paperless-db-dump.nix for why a file-level copy of an open
          WAL database is not a restorable artifact. Three copies of an index measured in
          single-digit MB is a cheap default; the originals beside it are the large thing and
          are not duplicated.

          Turning this OFF on a host whose backup excludes the live database is how a snapshot
          comes to hold documents and no record of what they are. hosts/kelpy asserts the pair.
        '';
      };

      onCalendar = lib.mkOption {
        type = lib.types.str;
        default = "02:45";
        description = ''
          When to take the dump, as a systemd `OnCalendar=`.

          COUPLED to the host's restic schedule and not freely choosable: kelpy's `daily` job
          runs at 03:00/15:00, so 02:45 leaves a quarter of an hour of slack and makes the
          day's first snapshot an almost-consistent pair of index and media — the same argument
          backup.nix makes for pairing 03:00 with Immich's 02:00 dump, and 02:45 rather than
          02:30 so this does not contend with the vault's dump on a 4 GB host.

          The timer carries NO `RandomizedDelaySec`: jitter here is what would let the dump land
          on top of the restic run it exists to feed.

          Move this and move `maxPaperlessDumpAgeSeconds` in hosts/kelpy/configuration.nix
          with it.
        '';
      };

      keep = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3;
        description = ''
          How many dumps to keep. Retention is ours — nothing else prunes them, so an
          unattended nightly would grow one full copy of the index per day, forever, on a host
          whose only real storage is 90G.

          Three is "last night, plus two chances to notice something wrong with it". An older
          dump is not a better restore point: it is an index missing every document filed
          since, pointed at media that has them.
        '';
      };
    };
  };

  # NOTE: nothing here contributes to `services.git-annex.*`, and that is a constraint rather
  # than an oversight. A generic profile cannot safely do it: gating the contribution on any
  # config/option value is a self-reference the module system resolves as infinite recursion,
  # and leaving it ungated breaks hosts that never import the git-annex module. The composition
  # layer that imports both modules would own such glue.
  #
  # ⚠ The previous version of this note said the media directory's git-annex backup "is wired at
  # the host level (see hosts/kelpy/git-annex.nix)". It is not and never was — that file defines
  # the `pictures` and `library` repositories only. What actually protects this service's state
  # is kelpy's restic `daily` job, which names /persistent/var/lib/paperless, excludes the live
  # database in favour of the dump below, and refuses to run if that dump goes stale.
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # The dump is `sqlite3 VACUUM INTO` against `${dataDir}/db.sqlite3`. Point paperless at
        # PostgreSQL and that file stops existing, so the unit would fail every night — loudly,
        # but for the wrong reason, and the host's backup would be gating on an artifact that
        # cannot be produced. rk1b's Immich job is the pattern to copy for a pg host: exclude
        # the cluster, ship a logical dump, gate its freshness.
        assertion =
          cfg.dump.enable
          -> (
            !(config.services.paperless.database.createLocally or false)
            && !(config.services.paperless.settings ? PAPERLESS_DBHOST)
          );
        message = "custom.profiles.paperless.dump is enabled, but this host points paperless at PostgreSQL (database.createLocally, or PAPERLESS_DBHOST in settings). The dump is a SQLite VACUUM INTO of ${dataDir}/db.sqlite3, which will not exist. Either leave paperless on SQLite or replace the dump with a pg_dump and move the freshness gate onto it (hosts/rk1/backup.nix does this for Immich).";
      }
    ];

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
      # The 2.20.15 → 3.x upgrade this unblocked LANDED on kelpy on 2026-10-19 (now 3.1.3). It
      # cost nothing, because the document library was — and still is — empty: the migration had
      # no rows to move. A host with documents in it should still take the backup the old note
      # here asked for before a major jump.
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

    systemd.services = lib.mkMerge [
      # Runtime OCR language, injected outside `services.paperless.settings` so it
      # does not trigger a language-limited tesseract rebuild (see note above).
      (lib.genAttrs
        [
          "paperless-consumer"
          "paperless-task-queue"
          "paperless-scheduler"
          "paperless-web"
        ]
        (_: {
          environment.PAPERLESS_OCR_LANGUAGE = "eng+spa+cat";
        })
      )

      # ── THE BACKUP ARTIFACT ──────────────────────────────────────────────────────────────
      # A nightly consistent dump of the document index, because the live database cannot be
      # backed up by copying it. The whole argument — and why this needs nothing from the
      # running service, and why it runs as the paperless user rather than root — is in
      # paperless-db-dump.nix, which holds the script so parts/checks/paperless-db-dump can
      # exercise the real one.
      (lib.mkIf cfg.dump.enable {
        paperless-db-dump = {
          description = "Take a consistent VACUUM INTO dump of the paperless document database";
          # NO `after = [ "paperless-web.service" ]` and no dependency on the service at all:
          # `VACUUM INTO` opens its own SQLite connection, so a dump does not need paperless
          # running — and must not be able to start it, nor be skipped because it is stopped.
          unitConfig.RequiresMountsFor = [ dataDir ];
          path = [
            pkgs.coreutils
            pkgs.findutils
            pkgs.sqlite
          ];
          serviceConfig = {
            Type = "oneshot";
            # The database's owner, not root. See the ⚠ in paperless-db-dump.nix: root opening
            # a WAL database can leave root-owned `-shm`/`-wal` files behind it, and paperless
            # then cannot write its own database.
            User = config.services.paperless.user;
            Group = config.users.users.${config.services.paperless.user}.group;
            # 0600 from creation rather than only after the explicit chmod, so the dump is never
            # momentarily group-readable inside a 0755 directory.
            UMask = "0077";
          };
          script = toString (
            import ./paperless-db-dump.nix {
              inherit pkgs lib dataDir;
              inherit (cfg.dump) keep;
              inherit (config.networking) hostName;
              post = alertPost.mkPost {
                name = "paperless-db-dump";
                webhookUrlFile = config.custom.profiles.matrix.infraAlerts.webhookUrlFile or null;
                # In-band only, like every other kelpy-side alerter: this runs ON the host that
                # serves the webhook, so an outage here stops the unit and there is no message
                # left to rescue (modules/shared/alert-post.nix).
                outOfBand = null;
              };
            }
          );
        };
      })
    ];

    systemd.timers.paperless-db-dump = lib.mkIf cfg.dump.enable {
      description = "Nightly consistent dump of the paperless document database";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.dump.onCalendar;
        # A missed dump is taken at boot rather than skipped — the host's freshness gate is
        # tuned on the assumption that downtime does not cost a dump.
        Persistent = true;
        # NO RandomizedDelaySec: this has to land before the host's restic run, and jitter is
        # exactly what would let it land during one.
        AccuracySec = "1m";
        Unit = "paperless-db-dump.service";
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

    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        dataDir
        "/var/lib/redis-paperless"
      ];
    };
  };
}
