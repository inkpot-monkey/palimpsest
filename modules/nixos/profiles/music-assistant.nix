# Music Assistant — the "brain" that plays the Navidrome library out of porcupineFish's
# speakers (ADR-0031). It speaks Subsonic/OpenSubsonic (reads Navidrome) *and* pushes audio
# to Snapcast, which nothing else does — so it is the library-plane control point, driven
# from Home Assistant (on rk1a) over the tailnet.
#
# Runs on rk1b, the media node, co-located with Navidrome + the git-annex library it scans
# and streams (HA is on rk1a; that link is a lightweight API call, not a co-location need).
# It drives the Pi's snapserver in *external-server* mode: it creates dynamic `tcp://` streams
# on the Pi over the control port and pushes audio to them — so snapserver stays on the Pi and
# MA never runs a server of its own here.
#
# MA's provider config (which Subsonic server, which snapserver) is normally UI-entered and
# stored Fernet-encrypted in settings.json. Instead a provisioning oneshot codifies it through
# MA's WebSocket API — the same declarative-ish pattern as navidrome-provision-users.
{
  config,
  lib,
  pkgs,
  self,
  settings,
  ...
}:
let
  cfg = config.custom.profiles.music-assistant;

  # MA and Navidrome are co-located on rk1b, so MA reaches the library over loopback — no TLS,
  # no Caddy hop. The port comes from the `music` service registry entry (Navidrome).
  navidromePort = settings.services.private.music.port;

  # The Pi's snapserver, reached over the tailnet (resolved via the monitoring peer-IP pin /
  # tailscale). MA connects here to add/push its streams.
  snapserverHost = "porcupineFish.${settings.tailnet}";
  snapserverControlPort = 1705;

  # MA's data dir on the NVMe. rk1b parks /var/cache on the NVMe (hosts/rk1/nvme.nix), and a
  # DynamicUser service's CacheDirectory=<name> lands at /var/cache/private/<name> on that disk
  # — the blessed mechanism there. MA's config (settings.json + its Fernet key) and library
  # cache therefore survive the tmpfs-root reboot, mount-gated so a missing NVMe can't strand
  # state on the eMMC.
  stateDir = "/var/cache/music-assistant";

  provisionScript = ./music-assistant-provision.py;
in
{
  imports = [
    # Declares `levelFromMessage`/`demoteToDebug`, which this profile sets below. Imported
    # rather than assumed: a VM test imports this profile without the monitoring client,
    # and a definition for an option nobody declared is an eval error.
    ./monitoring/log-levels.nix
  ];

  options.custom.profiles.music-assistant = {
    enable = lib.mkEnableOption "Music Assistant (the library-plane brain, ADR-0031)";
  };

  config = lib.mkIf cfg.enable {
    # Music Assistant is built on Home Assistant's core and logs in the same python format,
    # with one difference that matters to the regex: it colours every line by level, so the
    # pattern has to tolerate an ANSI prefix. Same catalogue entry as Home Assistant's, which
    # is the reason the catalogue exists.
    custom.profiles.monitoring-client.levelFromMessage."music-assistant.service" =
      self.lib.logLevelPatterns.pythonLogging;

    # MA reads Navidrome over loopback and provisions its service account via Navidrome's admin
    # API, so Navidrome must be enabled on this host. Fail the build loudly rather than reference
    # a missing navidrome_admin_password secret / dead loopback endpoint.
    assertions = [
      {
        assertion = config.custom.profiles.navidrome.enable;
        message = "custom.profiles.music-assistant requires custom.profiles.navidrome on the same host (it reads the library over loopback and provisions its account via Navidrome's admin API).";
      }
    ];

    services.music-assistant = {
      enable = true;
      # THE TEST SUITE IS NOT RUN HERE. `doCheck = false`, which on a package this size is a
      # big hammer, so the reasoning is written out rather than assumed.
      #
      # WHAT IT COSTS US, WHICH IS LESS THAN IT LOOKS. Hydra already builds and tests the
      # `providers = []` package — proven, not assumed: `nix build` of the un-overridden
      # `pkgs.music-assistant` substitutes straight from cache.nixos.org. And `providers` only
      # appends `providerDependencies` (python packages) to the derivation; it changes no source
      # file, no patch and no test. So running the suite HERE re-validates upstream's own work
      # against a slightly larger dependency closure. That is the entire signal being given up.
      #
      # WHAT IT BUYS. music-assistant runs its 13,300-test suite at build time, so ONE failure
      # takes the build down and with it every rk1b deploy — and the suite is full of wall-clock
      # races that are run on the fleet's slowest machine WHILE that machine is acting as its own
      # aarch64 build host. Three different tests have now blocked a deploy, each the only
      # failure in its run:
      #
      #   2026-11-10  test_join_fanout_before_history_feed_keeps_alignment      (sendspin)
      #   2026-11-16  test_promotion_flushes_join_backlog_before_live_pushes    (sendspin)
      #   2026-11-16  test_seekable_no_eviction_after_eof                       (streams)
      #
      # ⚠ AND SKIPPING THEM BY NAME DOES NOT CONVERGE. That was tried twice. The second failure
      # was a sibling of the first in one file, so the whole file went; the third was somewhere
      # else entirely — `tests/controllers/streams/test_audio_buffer.py`, which asserts a
      # background fill task has finished after a bare `await asyncio.sleep(0.1)` and contains 19
      # such sleeps on its own. There is no principled boundary to draw: the hazard is a loaded
      # 4-core SBC, not any one file, so a name-by-name skip list is an unbounded list that still
      # leaves the next deploy to chance.
      #
      # ⚠ THIS IS NOT A VERDICT ON THE SOFTWARE. Every one of these passes on a quieter machine.
      # A test that fails only under load is not a bug caught, it is a deploy that fails at
      # random, and trading a near-zero signal for that is the wrong way round.
      #
      # The one genuinely BROKEN test is kept recorded here, because it is the one thing a
      # re-enable would have to answer: `test_digital_silence_yields_finite_spectral_centroid`
      # (added in 2.9.13) initialises torch's QNNPACK quantized backend, unavailable on this
      # fleet's aarch64 builder — `RuntimeError: failed to initialize QNNPACK`. It belongs to
      # `smart_fades`, a provider this host does not run (see `providers` below). If the suite is
      # ever wanted back, run it on an idle builder and that failure is still real.
      #
      # `overrideAttrs`, NOT `overridePythonAttrs`: this module hands the package on as
      # `cfg.package.override { inherit (cfg) providers; }`, and only the former keeps `.override`
      # on the result (the latter drops it — `attribute 'override' missing`). The change must
      # survive that second override, which is the property that matters and is checked, not
      # assumed.
      package = pkgs.music-assistant.overrideAttrs (_old: {
        doCheck = false;
      });
      # The providers this design uses: read Navidrome (opensubsonic), push to the Pi's snapserver
      # (snapcast), and the Party plugin (guest QR access to a shared queue — the "Spotify Jam on
      # your own library" experience, ADR-0031). The stats scrobbler is a later, additive step.
      providers = [
        "opensubsonic"
        "snapcast"
        "party"
      ];
      # We manage the firewall (tailnet-only) below; the module's `openFirewall` defaults to false,
      # so it is deliberately left unset — every profile is imported into every host (incl. the
      # pi hosts, whose nixos-raspberrypi nixpkgs ships an older music-assistant module without
      # `openFirewall`), and assigning a non-existent option errors even under `mkIf false`.
      # Point MA's data at the NVMe dir instead of the module default (/var/lib, on tmpfs here).
      extraOptions = [
        "--config"
        stateDir
      ];
    };

    systemd.services.music-assistant = {
      # Land state on the NVMe (see stateDir note) and gate on that mount.
      environment.HOME = lib.mkForce stateDir;
      unitConfig.RequiresMountsFor = [ "/var/cache" ];
      serviceConfig.CacheDirectory = "music-assistant";
    };

    # Tailnet-only reachability for MA's API/web UI (8095): Home Assistant on rk1a controls MA
    # over this, and it's the operator's browser entry for troubleshooting. Not Caddy-fronted
    # (no public vhost) and not in the service registry — it's an internal integration, driven
    # through HA, not a user-facing site. The snapcast audio path is *outbound* from MA to the
    # Pi, so nothing needs MA's stream port inbound here.
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 8095 ];

    # --- PROVISIONING ONESHOT (fully declarative) ---
    # Bootstraps MA from scratch over its HTTP API (no manual UI onboarding): creates the Navidrome
    # `music-assistant` service account, creates MA's own admin via `POST /setup` (or logs in on
    # re-runs), then configures the opensubsonic + snapcast + party providers with the token. All
    # idempotent + create-only. See music-assistant-provision.py for the auth mechanics.
    #
    # One scalar in profiles/navidrome.yaml, deliberately OUT of the friend `users` map (a service
    # credential, not a listener): `music-assistant`. It serves DOUBLE DUTY as the password for
    #  * the Navidrome service account MA reads the library as, and
    #  * MA's OWN admin login (username `provisioner`). MA has no external-auth (only its builtin
    #    store + Home Assistant OAuth) so it can't reuse a Navidrome *user* — but its admin is a
    #    distinct account that can share this one secret VALUE (both are fleet secrets in the same
    #    file, on this host, handled by this one provisioner — reuse stays inside one trust boundary).
    # NB: MA's /setup requires the password to be >= 8 chars.
    sops.secrets.music_assistant_subsonic_password = {
      sopsFile = self.lib.getSecretFile "navidrome";
      key = "music-assistant";
    };

    systemd.services.music-assistant-provision = {
      description = "Provision Music Assistant (admin + Navidrome/Snapcast/Party providers) from sops";
      after = [
        "music-assistant.service"
        "navidrome.service"
        "navidrome-provision-users.service"
      ];
      requires = [ "music-assistant.service" ];
      wants = [ "navidrome.service" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.RequiresMountsFor = [ "/var/cache" ];
      environment = {
        # Navidrome native admin API (create the service account) + MA HTTP API.
        ND_URL = "http://127.0.0.1:${toString navidromePort}";
        ND_ADMIN_USER = "admin";
        MA_URL = "http://127.0.0.1:8095";
        MA_ADMIN_USER = "provisioner"; # MA's own admin login (its own credential; see the sops note)
        MA_SUBSONIC_BASEURL = "http://127.0.0.1";
        MA_SUBSONIC_PORT = toString navidromePort;
        MA_SUBSONIC_USER = "music-assistant";
        MA_SNAPCAST_HOST = snapserverHost;
        MA_SNAPCAST_CONTROL_PORT = toString snapserverControlPort;
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Passwords land in a per-service tmpfs (CREDENTIALS_DIRECTORY = %d), never argv/environ:
        #  * the `music-assistant` secret — reused for BOTH MA's admin login (/setup + re-run login)
        #    and the Navidrome service account (create + MA's subsonic login), and
        #  * the Navidrome admin password (to create that account via the native API).
        # Pure stdlib script — MA's schema-31 auth is handled over HTTP, so no extra python deps.
        LoadCredential = [
          "subsonic_password:${config.sops.secrets.music_assistant_subsonic_password.path}"
          "admin_password:${config.sops.secrets.navidrome_admin_password.path}"
        ];
        Environment = [
          "MA_ADMIN_PASSWORD_FILE=%d/subsonic_password"
          "MA_SUBSONIC_PASSWORD_FILE=%d/subsonic_password"
          "ND_ADMIN_PASSWORD_FILE=%d/admin_password"
        ];
        ExecStart = "${pkgs.python3}/bin/python3 ${provisionScript}";
      };
    };
  };
}
