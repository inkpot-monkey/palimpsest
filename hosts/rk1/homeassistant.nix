# Home Assistant + a local voice assistant for the Turing Pi RK1 node (rk1b).
#
# The wake word runs ON THE PHONE: the HA Android Companion app does on-device
# microWakeWord ("Okay Nabu") locally and only streams audio to Assist afterwards,
# so there is no server-side wake-word component here. This box just provides:
#   - Home Assistant core (the Assist pipeline + the mobile_app endpoint)
#   - speech-to-text via wyoming-faster-whisper (CTranslate2, CPU, no torch)
#   - text-to-speech via wyoming-piper
#
# The two Wyoming servers bind loopback (HA consumes them on the same host), so only
# HA itself is exposed — and only on the tailnet (the phone joins tailscale to reach it).
#
# Imported (inert) by hosts/rk1/common.nix; enable per node with:
#   custom.rk1.homeAssistant.enable = true;
#
# faster-whisper/piper run on CPU and may contend with the llama.cpp prefill burst, but
# voice latency isn't critical here. WhisperX (batch transcription/diarization, needs
# torch) is intentionally NOT here — it's staged behind the NVMe as a separate service.
{
  config,
  lib,
  settings,
  ...
}:
let
  cfg = config.custom.rk1.homeAssistant;
  haPort = settings.services.private.home.port;
  # Public-facing (tailnet-only) URL: kelpy's Caddy fronts HA at home.<domain> with TLS.
  haUrl = "https://home.${settings.nodes.kelpy.domain}";
in
{
  options.custom.rk1.homeAssistant = {
    enable = lib.mkEnableOption "Home Assistant + local Wyoming voice (STT/TTS) on this node";
  };

  config = lib.mkIf cfg.enable {
    services.home-assistant = {
      enable = true;

      # wyoming → add the Wyoming STT/TTS config entries in the UI; mobile_app → the
      # Companion app endpoint; default_config pulls in assist_pipeline + the standard set.
      extraComponents = [
        "default_config"
        "wyoming"
        "mobile_app"
        "met"
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
          # HA sits behind kelpy's Caddy. It rejects forwarded requests unless the proxy is
          # trusted, so trust kelpy's tailscale addresses. Direct http://rk1b:8123 access still
          # works (HA only enforces this when an X-Forwarded-For header is present).
          use_x_forwarded_for = true;
          trusted_proxies = [
            settings.nodes.kelpy.tailscale.ip4
            settings.nodes.kelpy.tailscale.ip6
          ];
        };
      };
    };

    # STT: faster-whisper over Wyoming, loopback only. base-int8 balances accuracy/size on
    # CPU; drop to tiny-int8 if eMMC/RAM is tight (see hosts/default.nix rk1b footprint notes).
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

    # Expose Home Assistant only on the tailnet, never the public LAN — mirrors the
    # llama.cpp rule in ./llm.nix. The phone reaches it over tailscale.
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ haPort ];
  };
}
