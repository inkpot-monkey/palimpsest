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

  # faster-whisper 1.2.x fetches the whisper tokenizer from HuggingFace at model load
  # UNLESS `tokenizer.json` is present in the model directory — and huggingface-hub 1.10.2
  # crash-loops that fetch ("Cannot send a request, as the client has been closed"), so the
  # STT service never starts. The rhasspy `base-int8` repo that `model = "base-int8"` pulls
  # ships only the ct2 essentials (model.bin/config.json/vocabulary.txt), no tokenizer.json.
  # Assemble a self-contained model dir — rhasspy's int8 weights + the matching tokenizer.json
  # from Systran's base repo — and point `model` at it. faster-whisper then loads the tokenizer
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
  fasterWhisperBaseInt8 = pkgs.runCommandLocal "faster-whisper-base-int8-model" { } ''
    mkdir -p "$out"
    cp ${
      hfFile {
        repo = "rhasspy/faster-whisper-base-int8";
        file = "model.bin";
        hash = "sha256-rhP3TbTSPCdGhjiA6H8Vv3gL0u4Ki5x92We5NDoicIE=";
      }
    } "$out/model.bin"
    cp ${
      hfFile {
        repo = "rhasspy/faster-whisper-base-int8";
        file = "config.json";
        hash = "sha256-yd7j1nXDHDdjwe48nnI1BQ6Hfa3ZACxbPGA2bj2B2io=";
      }
    } "$out/config.json"
    cp ${
      hfFile {
        repo = "rhasspy/faster-whisper-base-int8";
        file = "vocabulary.txt";
        hash = "sha256-NM4/4cUEECez+NQpEicJk/mG28S7NM8n+VHjSh5FORM=";
      }
    } "$out/vocabulary.txt"
    cp ${
      hfFile {
        repo = "Systran/faster-whisper-base";
        file = "tokenizer.json";
        hash = "sha256-+3tjGR6bsEUILHn9dCoxBqEsmVE6sw30oNR/pstv0Ks=";
      }
    } "$out/tokenizer.json"
  '';
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
    # CPU. `model` is a local, self-contained model dir (weights + tokenizer.json) rather than
    # the "base-int8" name — see fasterWhisperBaseInt8 above for why (offline, no crash-loop).
    services.wyoming.faster-whisper.servers.en = {
      enable = true;
      uri = "tcp://127.0.0.1:10300";
      model = "${fasterWhisperBaseInt8}";
      language = "en";
      device = "cpu";
    };

    # TTS: piper over Wyoming, loopback only.
    services.wyoming.piper.servers.en = {
      enable = true;
      uri = "tcp://127.0.0.1:10200";
      voice = "en_US-lessac-medium";
    };

    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [ "/var/lib/hass" ];
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
