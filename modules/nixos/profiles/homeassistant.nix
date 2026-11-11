# Home Assistant + a local Wyoming voice assistant (STT/TTS). A shared, host-agnostic
# profile, enabled with `custom.profiles.homeassistant.enable = true`.
#
# The wake word runs ON THE PHONE: the HA Android Companion app does on-device
# microWakeWord ("Okay Nabu") locally and only streams audio to Assist afterwards,
# so there is no server-side wake-word component here. This profile provides:
#   - Home Assistant core (the Assist pipeline + the mobile_app endpoint)
#   - speech-to-text via wyoming-faster-whisper (CTranslate2, CPU, no torch)
#   - text-to-speech via wyoming-piper
#
# The two Wyoming servers bind loopback (HA consumes them on the same host), so only
# HA itself is exposed — and only on the tailnet (the phone joins tailscale to reach it).
# STT/TTS run on CPU; a host that wants different size/quality trade-offs overrides the
# wyoming model/voice below directly.
{
  config,
  lib,
  pkgs,
  self,
  settings,
  ...
}:
let
  cfg = config.custom.profiles.homeassistant;
  # HA's endpoint metadata comes from its `home` service entry in settings: the port it
  # listens on, and the edge host — where Caddy fronts it at home.<domain> with TLS.
  haService = settings.services.private.home;
  haPort = haService.port;
  inherit (haService) edge;
  # Public-facing (tailnet-only) URL served by the edge host's Caddy.
  haUrl = "https://home.${settings.primaryDomain}";

  # The HTTP settings the provisioner holds in HA's store (see the NOTE by `config`).
  # HA sits behind the edge host's Caddy and rejects forwarded requests unless the
  # proxy is trusted, so trust that host's tailscale addresses. Direct access on the
  # origin host's own port still works — HA only enforces this when an
  # X-Forwarded-For header is present.
  haHttpConfig = {
    server_port = haPort;
    use_x_forwarded_for = true;
    trusted_proxies = [
      settings.nodes.${edge}.tailscale.ip4
      settings.nodes.${edge}.tailscale.ip6
    ];
  };

  # Where Home Assistant keeps its state, and who owns it — both read back from the
  # upstream module rather than restated, so the dump unit and the host's backup paths
  # cannot drift from where the service actually writes.
  haConfigDir = config.services.home-assistant.configDir;
  haUser = config.systemd.services.home-assistant.serviceConfig.User;

  # Shared alert delivery (modules/shared/alert-post.nix), as every other timer-driven
  # watcher on the fleet uses: in-band to #infra-alerts, falling back to the ADR-0020 push
  # relay where a host declares one.
  alertPost = import ../../shared/alert-post.nix { inherit lib pkgs; };

  # Bulbs, flattened into the shape ha-provision.py consumes. Keys are snake_case
  # because they are passed straight into tuya_local's config flow.
  haBulbs = lib.mapAttrsToList (slug: b: {
    inherit slug;
    inherit (b) title host area;
    device_id = b.deviceId;
    type = b.deviceType;
    protocol_version = b.protocolVersion;
    poll_only = b.pollOnly;
  }) cfg.provision.bulbs;

  # faster-whisper 1.2.x fetches the whisper tokenizer from HuggingFace at model load
  # UNLESS `tokenizer.json` is present in the model directory — and huggingface-hub 1.10.2
  # crash-loops that fetch ("Cannot send a request, as the client has been closed"), so the
  # STT service never starts. The rhasspy int8 repo that a bare `model` name pulls
  # ships only the ct2 essentials (model.bin/config.json/vocabulary.txt), no tokenizer.json.
  # Assemble a self-contained model dir — rhasspy's int8 weights + the matching tokenizer.json
  # from Systran's repo — and point `model` at it. faster-whisper then loads the tokenizer
  # from disk, never touches HuggingFace, and the model isn't re-downloaded to /tmp every boot.
  hfFile =
    {
      repo,
      file,
      hash,
    }:
    pkgs.fetchurl {
      url = "https://huggingface.co/${repo}/resolve/main/${file}";
      inherit hash;
    };
  fasterWhisperSmallInt8 = pkgs.runCommandLocal "faster-whisper-small-int8-model" { } ''
    mkdir -p "$out"
    cp ${
      hfFile {
        repo = "rhasspy/faster-whisper-small-int8";
        file = "model.bin";
        hash = "sha256-Tx7H0RRRUm8swyB6WhHCvfigNgGUAu8uHTP1j19TqlQ=";
      }
    } "$out/model.bin"
    cp ${
      hfFile {
        repo = "rhasspy/faster-whisper-small-int8";
        file = "config.json";
        hash = "sha256-yd7j1nXDHDdjwe48nnI1BQ6Hfa3ZACxbPGA2bj2B2io=";
      }
    } "$out/config.json"
    cp ${
      hfFile {
        repo = "rhasspy/faster-whisper-small-int8";
        file = "vocabulary.txt";
        hash = "sha256-NM4/4cUEECez+NQpEicJk/mG28S7NM8n+VHjSh5FORM=";
      }
    } "$out/vocabulary.txt"
    cp ${
      hfFile {
        repo = "Systran/faster-whisper-small";
        file = "tokenizer.json";
        hash = "sha256-+3tjGR6bsEUILHn9dCoxBqEsmVE6sw30oNR/pstv0Ks=";
      }
    } "$out/tokenizer.json"
  '';
in
{
  options.custom.profiles.homeassistant = {
    enable = lib.mkEnableOption "Home Assistant + local Wyoming voice (STT/TTS)";

    logging = {
      fileLog = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Let Home Assistant keep its own `home-assistant.log` in the config directory,
          in addition to the journal.

          OFF, because on this fleet it is a second copy of a log that already has a
          home. Home Assistant writes every line to stdout, which systemd puts in the
          journal, which Vector ships to VictoriaLogs (ADR-0021) — so the file duplicates
          all of it inside the one directory on this host that gets BACKED UP, where it
          churns every night and defeats restic's deduplication for no restore value.
          `HA_DISABLE_LOG_FILE` is Home Assistant's own supported switch for exactly this
          (it is what a supervised install uses, where the supervisor owns logging), so
          this is a documented mode and not a trick.

          What it costs: Settings → System → Logs loses its "Load full logs" download,
          because that endpoint serves this file. The panel's live error list is in-memory
          and unaffected, and the full history is `journalctl -u home-assistant` or the
          Logs dashboard — which is the fleet's answer for every other service.

          Turning it back on does not retrieve what was already renamed: on the deploy
          that disables it, Home Assistant renames any existing log to
          `home-assistant.log.old` and leaves it. The backup excludes
          `home-assistant.log*`, so neither the file nor that leftover travels.
        '';
      };
    };

    backup = {
      dump = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Take a nightly `VACUUM INTO` dump of the recorder database beside the live one.

            On by default, because a host that backs up this directory at all would
            otherwise be shipping a torn copy of an open WAL database — see
            modules/nixos/profiles/ha-db-dump.nix for why that is not a restorable
            artifact, and for the argument that the long-term statistics inside it are the
            one part of Home Assistant's state that nothing can regenerate. Three copies
            of a single-digit-MB database is a cheap default.

            Harmless on a host that does NOT back up: the dumps simply sit in the config
            directory, pruned to `keep`. What makes them load-bearing is the host naming
            ha-dump-freshness.nix as its `backupPrepareCommand`.
          '';
        };

        onCalendar = lib.mkOption {
          type = lib.types.str;
          default = "02,14:45";
          description = ''
            When to take the dump, as a systemd `OnCalendar=` — 02:45 and 14:45.

            ⚠ THE SPELLING IS A TRAP, and it cost a deploy. `OnCalendar` is
            `<hours>:<minutes>:<seconds>`, so two times a day is an HOUR LIST —
            `02,14:45`. The obvious-looking `"02:45,14:45"` is accepted silently and
            means something else entirely: systemd reads it as hours `02`, minutes
            `45,14`, seconds `45`, and normalises it to `*-*-* 02:14,45:45` — two runs in
            the small hours and nothing in the afternoon. Nothing fails; the dump simply
            stops being where the backup needs it. `systemd-analyze calendar "<value>"`
            prints the normalised form, and parts/checks/ha-dump-schedule runs that real
            parser over this value against the host's restic schedule, so the next person
            gets a build failure instead of a silently misplaced dump.

            COUPLED to the host's restic schedule and not freely choosable: the `daily` job
            runs at 03:00/15:00, so this leaves a quarter of an hour of slack before each
            run and makes BOTH snapshots an almost-consistent pair of history and
            configuration.

            Twice, where paperless's equivalent dumps once at 02:45 and lets its 15:00
            snapshot carry a 12h-old index. The difference is cost: this dump is a
            single-digit-MB file produced in under a second, so there is no reason for the
            afternoon snapshot to carry stale history, whereas paperless's is a bigger
            index on a host whose only storage is 90G.

            The timer carries NO `RandomizedDelaySec`: jitter here is what would let a dump
            land on top of the restic run it exists to feed.

            Move this and move `maxDumpAgeSeconds` in hosts/rk1/ha-backup.nix with it.
          '';
        };

        keep = lib.mkOption {
          type = lib.types.ints.positive;
          default = 3;
          description = ''
            How many dumps to keep. Retention is ours — nothing else prunes them, so an
            unattended nightly would grow one full copy of the recorder per run, forever,
            on a host whose only real storage is a 29 GB eMMC already at 79%.

            Three is "the last run, plus two chances to notice something wrong with it".
            An older dump is not a better restore point: it is history missing everything
            since, against a configuration that has moved on.
          '';
        };
      };
    };

    provision = {
      enable = lib.mkEnableOption ''
        a post-start oneshot that pushes the state Home Assistant keeps in its
        mutable `.storage` — the HTTP settings, the Assist pipeline's Wyoming
        STT/TTS, and the tuya_local bulbs — through HA's own supported APIs
        (ha-provision.py). Idempotent and fail-loud; reads the `username` +
        `password` from the homeassistant sops secret. HA has no declarative path
        for config entries, so this codifies what would otherwise be UI clicks'';
      ownerName = lib.mkOption {
        type = lib.types.str;
        default = "Administrator";
        description = "Display name for the HA owner account created on first run.";
      };

      bulbs = lib.mkOption {
        default = { };
        example = lib.literalExpression ''
          {
            bulb_office = {
              title = "bulb office";
              deviceId = "bfad3cfdefffd705a3tgsq";
              host = "192.168.1.27";
              deviceType = "rgbcw_lightbulb_xld_cl002";
              protocolVersion = "3.5";
              area = "Office";
            };
          }
        '';
        description = ''
          Tuya bulbs to adopt through the `tuya_local` integration, keyed by slug.
          Each bulb's Tuya local key is read from the homeassistant sops secret
          under `local_key_<slug>`, so adding a bulb here means adding that key
          to stash as well (ADR-0037).

          The bulbs keep their vendor firmware and are driven directly on the LAN,
          so nothing here reaches Tuya's cloud. `host` must be a reserved address:
          tuya_local is configured with an address, not a name, so a DHCP lease
          change silently breaks control.
        '';
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              title = lib.mkOption {
                type = lib.types.str;
                description = "Device name shown in Home Assistant.";
              };
              deviceId = lib.mkOption {
                type = lib.types.str;
                description = ''
                  The bulb's Tuya device id — the "Virtual ID" in the Smart Life
                  app. Doubles as the config entry's unique id, which is how the
                  provisioner knows whether the bulb is already adopted.
                '';
              };
              host = lib.mkOption {
                type = lib.types.str;
                description = "The bulb's LAN address (reserved in DHCP).";
              };
              deviceType = lib.mkOption {
                type = lib.types.str;
                description = ''
                  tuya_local device config to use, e.g. `rgbcw_lightbulb_xld_cl002`.
                  The integration logs which config it matched, and at what quality,
                  when a device is added by hand.
                '';
              };
              protocolVersion = lib.mkOption {
                type = lib.types.str;
                default = "auto";
                description = ''
                  Tuya protocol version. `auto` probes every version on each connect;
                  pinning the version the probe found makes restarts connect straight
                  away.
                '';
              };
              pollOnly = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Poll instead of subscribing, for devices that push badly.";
              };
              area = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = ''
                  Home Assistant Area to place the device in, created if absent.
                  This is what lets Assist address it by room ("turn on the office
                  light"), so leaving it null costs voice control.
                '';
              };
            };
          }
        );
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        services.home-assistant = {
          enable = true;

          # wyoming → add the Wyoming STT/TTS config entries in the UI; mobile_app → the
          # Companion app endpoint; default_config pulls in assist_pipeline + the standard set.
          # esphome → adopt LAN ESPHome devices (e.g. the cloudcutter-flashed smart bulbs, see
          # ADR-0015). It is not in default_config and HA cannot pip-install it at runtime on
          # NixOS, so it must be declared; the device itself is added as a UI config entry.
          extraComponents = [
            "default_config"
            "wyoming"
            "mobile_app"
            "met"
            "esphome"
          ];

          # Local control of the Antela bulbs. Their stock firmware (v1.6.3, Tuya SDK
          # 3.3.44, built 2024-12-12) is on tuya-cloudcutter's confirmed-patched list, so
          # ESPHome cannot be flashed onto them over the air and ADR-0015's transport is
          # void for this hardware — see ADR-0037. tuya_local speaks the Tuya protocol
          # straight to the bulb's LAN address instead, so control never leaves the house.
          # nixpkgs packages it along with its tinytuya dependency, which keeps it
          # declarative — no HACS, no runtime pip. No firewall rule is needed: HA dials the
          # bulb outbound on TCP 6668 and the device pushes state back over that same
          # connection. Each bulb is a UI config entry, because the integration is
          # config-flow only and declares no discovery (no dhcp/zeroconf/ssdp in its
          # manifest), so HA cannot find it on its own: host, device id and local key are
          # entered by hand.
          customComponents = [ pkgs.home-assistant-custom-components.tuya_local ];

          # A declarative config is required for the module to manage configuration.yaml. The
          # Assist pipeline and the Wyoming STT/TTS integrations are config-entry integrations,
          # added once in the UI (stored under /var/lib/hass/.storage) — they can't live here.
          config = {
            default_config = { };
            # Canonical URL is the proxied tailnet name (used by the Companion app + links).
            homeassistant = {
              external_url = haUrl;
              internal_url = haUrl;
              # Without a country HA raises a repair and cannot pick regional defaults.
              country = "ES";
            };
          };

          # NOTE: there is deliberately no `http` block here. HA 2026.9 migrated the
          # http integration out of configuration.yaml into its own store and now
          # *ignores* the YAML — it raises two repairs telling you to delete it, and a
          # change made here would silently never take effect. The same settings are
          # declared in `haHttpConfig` below and pushed in by the provisioner, which is
          # the only remaining way to hold them from nix.
        };

        # ── LOGGING ──────────────────────────────────────────────────────────────────────
        # One log path, not two. Home Assistant writes every line to stdout AND, by
        # default, to its own rotating `home-assistant.log` in the config directory. On
        # this fleet the first is the real one: systemd puts it in the journal and Vector
        # ships it to VictoriaLogs (ADR-0021). The second is a duplicate living in the one
        # directory on this host that is BACKED UP. See `logging.fileLog` for what turning
        # it off costs in the UI.
        systemd.services.home-assistant.environment = lib.mkIf (!cfg.logging.fileLog) {
          HA_DISABLE_LOG_FILE = "1";
        };

        # Home Assistant's severity is in its MESSAGE, not in journald's PRIORITY — it
        # logs to stdout, so journald stamps every line, errors included, PRIORITY=6
        # (info). Vector derives `level` from PRIORITY, and `level` is what the Logs
        # dashboard's whole Errors/Warnings half selects on — so before this, 396 HA
        # ERROR/WARNING lines in 24h on rk1a were invisible to every error view the fleet
        # has while reading perfectly well in `journalctl`. The pattern is anchored on HA's
        # own log format (timestamp, level, `(Thread)`) so a line that merely contains the
        # word "error" is not promoted; see monitoring/client.nix for the mechanism and for
        # what deliberately stays unmatched (traceback continuation lines).
        #
        # Declared unconditionally: the option exists whether or not this host enables the
        # monitoring client, and the consuming module is mkIf-gated, so on a host without
        # Vector this is an inert fact rather than a dependency.
        custom.profiles.monitoring-client.levelFromMessage."home-assistant.service" =
          ''^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+ (?P<lvl>DEBUG|INFO|WARNING|ERROR|CRITICAL) \('';

        # STT: faster-whisper over Wyoming, loopback only, on `small-int8`.
        #
        # This was `base-int8` until the transcriptions were actually measured: across ten
        # recorded pipeline runs it got 6 right, rendering "turn on the office light" as
        # "turn on the off-the-slide" and, on weak audio, hallucinating a flat "Cancel."
        # — the classic smallest-tier failures. small-int8 costs 243 MB of weights against
        # base's 76 MB and more CPU per utterance, which this host can spend: 8 idle A76
        # cores, 28 GB of free RAM, and voice latency that is not critical here.
        #
        # `model` is a local, self-contained model dir (weights + tokenizer.json) rather than
        # a bare model name — see fasterWhisperSmallInt8 above for why (offline, no crash-loop).
        services.wyoming.faster-whisper.servers.en = {
          enable = true;
          uri = "tcp://127.0.0.1:10300";
          model = "${fasterWhisperSmallInt8}";
          language = "en";
          device = "cpu";
        };

        # TTS: piper over Wyoming, loopback only. The voice must stay in step with
        # ha-provision.py's TTS_VOICE/TTS_LANG, and piper only accepts a
        # region-qualified language — a bare "en" is rejected at speak time, which
        # reaches the user as an unexplained error in the companion app.
        services.wyoming.piper.servers.en = {
          enable = true;
          uri = "tcp://127.0.0.1:10200";
          voice = "en_GB-northern_english_male-medium";
        };

        # Persist HA state, and declare its owner. On a fresh host, impermanence creates
        # the persistent source dir before home-assistant.service first runs; the plain
        # string form creates it root:root, which then masks systemd's StateDirectory
        # chown (the source is bind-mounted over /var/lib/hass), so HA's pre-start can't
        # write configuration.yaml and the unit crash-loops on "Permission denied". Giving
        # the entry an explicit user/group makes the dir hass-owned at creation, so a
        # from-scratch rk1a comes up without a manual chown. See [[kelpy-uid-map-drift]].
        environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
          directories = [
            {
              directory = "/var/lib/hass";
              user = "hass";
              group = "hass";
              mode = "0700";
            }
          ];
        };

        # Expose Home Assistant only on the tailnet, never the public LAN. The phone reaches it
        # over tailscale.
        networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ haPort ];

        # ESPHome devices announce themselves over mDNS, so HA needs to receive multicast on
        # 5353 from the LAN to auto-discover them (control is outbound TCP 6053, already allowed).
        # Unlike HA's own port this is opened on every interface: mDNS is inherently a LAN
        # broadcast and the upstream turing-rk1 module owns the LAN interface name. See ADR-0015.
        networking.firewall.allowedUDPPorts = [ 5353 ];
      }

      # ── THE BACKUP ARTIFACT ────────────────────────────────────────────────────────────
      # A nightly consistent dump of the recorder database, because the live one cannot be
      # backed up by copying it. The whole argument — why a dump, why not Home Assistant's
      # own backup integration, why it needs nothing from the running service, and how to
      # restore from it — is in ha-db-dump.nix, which holds the script so
      # parts/checks/ha-db-dump can exercise the real one.
      (lib.mkIf (cfg.enable && cfg.backup.dump.enable) {
        systemd.services.ha-db-dump = {
          description = "Take a consistent VACUUM INTO dump of the Home Assistant recorder database";
          # ⚠ ALSO RUN AT ACTIVATION AND BOOT, not only on the timer. This closes the
          # BOOTSTRAP HOLE that took kelpy's backup down on 2026-11-10, the very first
          # deploy carrying its paperless equivalent: the freshness gate refuses the job
          # when no dump exists — correctly, that is its whole job — but on a fresh deploy
          # the timer has not fired yet, so there was no dump, so the gate refused, so
          # NOTHING was backed up on that host. A guard meant to protect one service had
          # switched the backup off for all of them. `wantedBy = multi-user.target` on a
          # `RemainAfterExit`-less oneshot means it runs on this deploy and every boot, so
          # an artifact exists from the moment the profile lands.
          #
          # (ha-dump-freshness.nix also refuses to repeat that outage from the other end:
          # with no live database there is nothing being excluded, so it passes rather than
          # blocking `.storage`. Both ends, because either alone leaves the hole open in
          # one direction.)
          wantedBy = [ "multi-user.target" ];
          # NO dependency on home-assistant.service, deliberately: `VACUUM INTO` opens its
          # own SQLite connection, so a dump does not need Home Assistant running — and
          # must not be able to START it, nor be skipped because it is stopped. A dump is
          # most wanted precisely when the service is crash-looping.
          unitConfig.RequiresMountsFor = [ haConfigDir ];
          path = [
            pkgs.sqlite
            pkgs.coreutils
            pkgs.findutils
          ];
          serviceConfig = {
            Type = "oneshot";
            # The database's owner, not root. See the ⚠ in ha-db-dump.nix: root opening a
            # WAL database can leave root-owned `-shm`/`-wal` files behind it, and Home
            # Assistant then cannot write its own database on next start.
            User = haUser;
            Group = haUser;
            # 0600 from creation rather than only after the explicit chmod, so the dump is
            # never momentarily readable by anything that can reach this directory.
            UMask = "0077";
          };
          script = toString (
            import ./ha-db-dump.nix {
              inherit pkgs lib;
              configDir = haConfigDir;
              inherit (cfg.backup.dump) keep;
              inherit (config.networking) hostName;
              post = alertPost.mkPost {
                name = "ha-db-dump";
                # Null on rk1a, which holds no matrix credential (profiles/matrix.yaml is
                # keyed to admin, kelpy and rk1b only) — so `post` degrades to a log line
                # and the journal is the signal. Read from the option rather than hardcoded
                # so a host that DOES serve #infra-alerts gets the alert for free.
                webhookUrlFile = config.custom.profiles.matrix.infraAlerts.webhookUrlFile or null;
                outOfBand = alertPost.oobFromWatcher config;
              };
            }
          );
        };

        systemd.timers.ha-db-dump = {
          description = "Consistent dump of the Home Assistant recorder database";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = cfg.backup.dump.onCalendar;
            # A missed dump is taken at boot rather than skipped — the host's freshness
            # gate is tuned on the assumption that downtime does not cost a dump.
            Persistent = true;
            # NO RandomizedDelaySec: this has to land before the host's restic run, and
            # jitter is exactly what would let it land during one.
            AccuracySec = "1m";
            Unit = "ha-db-dump.service";
          };
        };
      })

      # Post-start provisioner (opt-in): codify the one-time UI wiring of the Assist
      # pipeline to the local Wyoming STT/TTS, the HTTP settings HA stopped reading
      # from configuration.yaml in 2026.9, and the tuya_local bulbs. HA has no
      # declarative path for any of it, so ha-provision.py drives HA's supported APIs
      # instead — idempotent (safe to re-run, and it must be: applying an HTTP config
      # restarts HA) and fail-loud (a failed unit means broken wiring).
      # See docs/runbooks/ha-provisioning.md.
      (lib.mkIf cfg.provision.enable {
        # HA owner credentials (username + password) from the sops secret: onboards
        # the owner on a fresh HA and logs in thereafter. Both live in the new sops
        # file profiles/homeassistant.yaml (keys `username` + `password`), keyed to
        # admin + rk1a in secrets/.sops.yaml (mind the all-or-nothing-per-host rule).
        sops.secrets = {
          ha_owner_username = {
            sopsFile = self.lib.getSecretFile "homeassistant";
            key = "username";
          };
          ha_owner_password = {
            sopsFile = self.lib.getSecretFile "homeassistant";
            key = "password";
          };
        }
        # One Tuya local key per bulb, from the same file — it is already keyed to
        # exactly the right pair (admin + this host), and sops grants per file.
        // lib.mapAttrs' (
          slug: _:
          lib.nameValuePair "ha_local_key_${slug}" {
            sopsFile = self.lib.getSecretFile "homeassistant";
            key = "local_key_${slug}";
          }
        ) cfg.provision.bulbs;

        systemd.services.home-assistant-provision = {
          description = "Provision HA HTTP config, Assist voice pipeline and bulbs";
          after = [
            "home-assistant.service"
            "wyoming-faster-whisper-en.service"
            "wyoming-piper-en.service"
          ];
          wants = [
            "wyoming-faster-whisper-en.service"
            "wyoming-piper-en.service"
          ];
          requires = [ "home-assistant.service" ];
          wantedBy = [ "multi-user.target" ];
          environment = {
            HA_URL = "http://127.0.0.1:${toString haPort}";
            HA_OWNER_NAME = cfg.provision.ownerName;
            # The settings HA stopped reading from configuration.yaml in 2026.9.
            HA_HTTP_CONFIG = builtins.toJSON haHttpConfig;
            HA_BULBS = builtins.toJSON haBulbs;
          };
          # Self-heal transient boot races (e.g. assist_pipeline's WS API not yet
          # registered, HA restarting mid-provision): retry a few times, spaced
          # out, over a 10min window, then give up visibly rather than silently
          # sitting failed. The window must exceed RestartSec * burst or systemd
          # rate-limits the retries away instantly.
          startLimitIntervalSec = 600;
          startLimitBurst = 6;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            Restart = "on-failure";
            RestartSec = 30;
            # LoadCredential drops each secret into a per-service tmpfs, not the env of
            # unrelated processes; the wrapper reads them into HA_OWNER_USERNAME/PASSWORD.
            LoadCredential = [
              "owner_username:${config.sops.secrets.ha_owner_username.path}"
              "owner_password:${config.sops.secrets.ha_owner_password.path}"
            ]
            ++ lib.mapAttrsToList (
              slug: _: "local_key_${slug}:${config.sops.secrets."ha_local_key_${slug}".path}"
            ) cfg.provision.bulbs;
            # HA takes ~30-60s to boot on first run; wait for its API, then provision.
            # Bulb local keys stay in the credentials directory: the script reads
            # each one from there itself, so no key is ever an env var.
            ExecStart = pkgs.writeShellScript "ha-provision" ''
              set -euo pipefail
              for _ in $(seq 1 90); do
                code=$(${pkgs.curl}/bin/curl -s -o /dev/null -w '%{http_code}' \
                  "$HA_URL/manifest.json" || true)
                [ "$code" = "200" ] && break
                sleep 2
              done
              export HA_OWNER_USERNAME="$(cat "$CREDENTIALS_DIRECTORY/owner_username")"
              export HA_OWNER_PASSWORD="$(cat "$CREDENTIALS_DIRECTORY/owner_password")"
              exec ${pkgs.python3}/bin/python3 ${../../../hosts/rk1/ha-provision.py}
            '';
          };
        };
      })
    ]
  );
}
