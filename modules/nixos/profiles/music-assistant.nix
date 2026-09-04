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
  options.custom.profiles.music-assistant = {
    enable = lib.mkEnableOption "Music Assistant (the library-plane brain, ADR-0031)";
  };

  config = lib.mkIf cfg.enable {
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
      # ONE TEST SKIPPED, and only on the way past a builder limitation. music-assistant runs its
      # suite at build time, and 2.9.13 added `test_digital_silence_yields_finite_spectral_centroid`,
      # which initialises torch's QNNPACK quantized backend — unavailable on this fleet's aarch64
      # builder, so it errors with `RuntimeError: failed to initialize QNNPACK`. 3271 tests pass and
      # that one takes the build down, and with it every rk1b deploy.
      #
      # It belongs to the `smart_fades` provider, which this host does not run (see `providers`
      # below), so what is skipped is a test for code that is never loaded here. If smart_fades is
      # ever wanted on this node, the QNNPACK question is real and this skip is not the answer.
      # `overrideAttrs`, NOT `overridePythonAttrs`: this module hands the package on as
      # `cfg.package.override { inherit (cfg) providers; }`, and only the former keeps `.override`
      # on the result (the latter drops it — `attribute 'override' missing`). The skip survives
      # that second override, which is the property that matters and is checked, not assumed.
      package = pkgs.music-assistant.overrideAttrs (old: {
        disabledTests = (old.disabledTests or [ ]) ++ [
          "test_digital_silence_yields_finite_spectral_centroid"
        ];
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
