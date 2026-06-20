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
in
{
  options.custom.profiles.homeassistant = {
    enable = lib.mkEnableOption "Home Assistant + local Wyoming voice (STT/TTS)";
  };

  config = lib.mkIf cfg.enable {
    services.home-assistant = {
      enable = true;

      # wyoming → add the Wyoming STT/TTS config entries in the UI; mobile_app → the
      # Companion app endpoint; default_config pulls in assist_pipeline + the standard set.
      # esphome → adopt LAN ESPHome devices (e.g. the cloudcutter-flashed smart bulbs, see
      # ADR-0016). It is not in default_config and HA cannot pip-install it at runtime on
      # NixOS, so it must be declared; the device itself is added as a UI config entry.
      extraComponents = [
        "default_config"
        "wyoming"
        "mobile_app"
        "met"
        "esphome"
      ];

      # A declarative config is required for the module to manage configuration.yaml. The
      # Assist pipeline and the Wyoming STT/TTS integrations are config-entry integrations,
      # added once in the UI (stored under /var/lib/hass/.storage) — they can't live here.
      config = {
        default_config = { };
        # Canonical URL is the proxied tailnet name (used by the Companion app + links).
        homeassistant = {
          external_url = haUrl;
          internal_url = haUrl;
        };
        http = {
          server_port = haPort;
          # HA sits behind the edge host's Caddy. It rejects forwarded requests unless the
          # proxy is trusted, so trust that host's tailscale addresses. Direct access on the
          # origin host's own port still works (HA only enforces this when an X-Forwarded-For
          # header is present).
          use_x_forwarded_for = true;
          trusted_proxies = [
            settings.nodes.${edge}.tailscale.ip4
            settings.nodes.${edge}.tailscale.ip6
          ];
        };
      };
    };

    # STT: faster-whisper over Wyoming, loopback only. base-int8 balances accuracy/size on
    # CPU; a RAM-constrained host can override `.model` to tiny-int8.
    services.wyoming.faster-whisper.servers.en = {
      enable = true;
      uri = "tcp://127.0.0.1:10300";
      model = "base-int8";
      language = "en";
      device = "cpu";
    };

    # TTS: piper over Wyoming, loopback only.
    services.wyoming.piper.servers.en = {
      enable = true;
      uri = "tcp://127.0.0.1:10200";
      voice = "en_US-lessac-medium";
    };

    # Expose Home Assistant only on the tailnet, never the public LAN. The phone reaches it
    # over tailscale.
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ haPort ];

    # ESPHome devices announce themselves over mDNS, so HA needs to receive multicast on
    # 5353 from the LAN to auto-discover them (control is outbound TCP 6053, already allowed).
    # Unlike HA's own port this is opened on every interface: mDNS is inherently a LAN
    # broadcast and the upstream turing-rk1 module owns the LAN interface name. See ADR-0016.
    networking.firewall.allowedUDPPorts = [ 5353 ];
  };
}
