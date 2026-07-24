{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.custom.profiles.hifi;

  # The one process that opens the DAC. Everything else feeds snapserver.
  soundcard = "hw:sndrpihifiberry";

  # librespot's zeroconf (Spotify Connect discovery) is pinned to a fixed TCP port so the
  # firewall can open exactly it on the LAN — otherwise librespot picks a random port and
  # the phone can't be let through. Mirrors the old spotifyd 5354 choice.
  spotifyZeroconfPort = 5354;

  # Spotify becomes a snapserver `librespot` stream instead of a standalone daemon
  # (spotifyd can't feed snapserver — no pipe backend; snapserver runs `librespot
  # --backend pipe` itself, the clean path Volumio uses). Zeroconf mode: no stored
  # credentials, the phone hands off the session. `devicename` is what shows in the
  # Spotify app; `name` is the snapcast stream/tab name. `params` passes raw args through
  # to librespot — here the pinned zeroconf port. (ADR-0031)
  librespotSource = lib.concatStrings [
    "librespot:///${lib.getExe pkgs.librespot}"
    "?name=Spotify"
    "&devicename=porcupineFish"
    "&bitrate=320"
    "&normalize=true"
    "&params=--zeroconf-port ${toString spotifyZeroconfPort}"
  ];
in
{
  options.custom.profiles.hifi = {
    enable = lib.mkEnableOption "High-fidelity audio (Snapcast sound-server) configuration for Raspberry Pi";
  };

  config = lib.mkIf cfg.enable {
    # This profile drives `hw:sndrpihifiberry`, so it is meaningless without the
    # HiFiBerry hardware profile (which declares the card, ALSA tooling and mixer
    # persistence). Fail the build loudly rather than ship a silent misconfig.
    assertions = [
      {
        assertion = config.custom.profiles.hifiberry.enable;
        message = "custom.profiles.hifi requires custom.profiles.hifiberry (it drives hw:sndrpihifiberry).";
      }
    ];

    # --- AUDIO STACK (ALSA Direct, single owner) ---
    # No PulseAudio/PipeWire: snapclient is the *sole* process that opens the DAC, and it
    # holds it open continuously (see the snapclient unit). This is the whole point of the
    # redesign — one persistent ALSA opener instead of N sources churning the PCM, which is
    # the trigger for the SoC I²S clock wedge (hosts/porcupineFish/RUNBOOK-audio-silence.md).
    services.pulseaudio.enable = false;

    # --- SNAPSERVER (the audio router; sources feed it, it never opens the card) ---
    # snapserver runs on the Pi so Spotify and the audio decisions stay on this self-contained
    # appliance and do not depend on rk1b. It hosts:
    #   * a static `librespot` stream (Spotify Connect), and
    #   * the dynamic `tcp://` streams Music Assistant (on rk1b) creates over the control port.
    # The local snapclient plays whichever stream its group is assigned to.
    services.snapserver = {
      enable = true;
      # openFirewall would open tcp-streaming + tcp-control + http on ALL interfaces; we want
      # a much tighter posture (loopback streaming, tailnet-only control), so it stays off and
      # the firewall is hand-written below.
      openFirewall = false;
      settings = {
        stream = {
          source = [ librespotSource ];
          # MA pushes 48000:16:2; resample everything to it so streams are interchangeable.
          sampleformat = "48000:16:2";
          # Localhost hop to a single client — FLAC is cheap on an A72 and the safe, well-worn
          # codec (pcm has historically been rougher across snap versions). Latency from the
          # sync buffer is ~1s, which is fine for music.
          codec = "flac";
        };
        # Audio to snapclients. The only client is local, so bind loopback — never exposed.
        tcp-streaming = {
          enabled = true;
          bind_to_address = "127.0.0.1";
          port = 1704;
        };
        # JSON-RPC control. This is what Music Assistant on rk1b connects to (Stream.AddStream
        # etc.). Bind all interfaces; the firewall opens it on tailscale0 only.
        tcp-control = {
          enabled = true;
          port = 1705;
        };
        # snapweb, on 1780 — a reliable manual stream-switcher for the two control planes
        # (e.g. switch the group to the Spotify stream). Tailnet-only via the firewall.
        http = {
          enabled = true;
          port = 1780;
        };
      };
    };

    # --- SNAPCLIENT (the sole, always-on ALSA owner) ---
    # There is no NixOS module for snapclient, so it is a hand-written unit. It connects to the
    # local snapserver and opens `hw:sndrpihifiberry`. The design intent is that it holds the
    # PCM (and thus the I²S clock) open 24/7 so nothing ever churns the device — the untried
    # "keep the clock always-on" wedge cure (see hosts/porcupineFish/porcupinefish-moode notes).
    #
    # VERIFY ON BOX (the linchpin of the wedge cure): confirm snapclient does NOT release the
    # PCM when the stream goes idle. If it does, keep it warm (e.g. snapserver silence / a
    # `--sampleformat`-forced idle tone) so the clock never stops.
    users.users.snapclient = {
      isSystemUser = true;
      group = "snapclient";
      extraGroups = [ "audio" ];
    };
    users.groups.snapclient = { };

    systemd.services.snapclient = {
      description = "Snapclient — sole always-on owner of the HiFiBerry DAC";
      wantedBy = [ "multi-user.target" ];
      after = [
        "snapserver.service"
        "sound.target"
      ];
      wants = [ "snapserver.service" ];
      serviceConfig = {
        # --mixer hardware:Digital keeps volume in the DAC's PCM512x "Digital" control at full
        # bit-depth — the fidelity rationale the old spotifyd volume_controller=alsa carried.
        # The control MUST be named: bare `--mixer hardware` defaults to a "PCM" control this card
        # doesn't have (verified on box: `Failed to find mixer: PCM`); "Digital" is the right one
        # (same control spotifyd drove). The URI form of the server address replaces the deprecated
        # --host/--port. (Fall back to `--mixer software` only if hardware ever can't be aimed —
        # that reintroduces digital-attenuation bit loss.)
        ExecStart = toString [
          (lib.getExe' pkgs.snapcast "snapclient")
          "--player alsa"
          "--soundcard ${soundcard}"
          "--mixer hardware:Digital"
          "--hostID porcupineFish"
          "--logsink system"
          "tcp://127.0.0.1:1704"
        ];
        User = "snapclient";
        Group = "snapclient";
        Restart = "always";
        RestartSec = 5;
        # Run the audio output thread under SCHED_FIFO so it preempts normal work (XRUN
        # insurance under CPU contention — e.g. a nix GC mid-play). systemd applies the policy
        # as root before dropping privileges, so no CAP_SYS_NICE is needed. Priority kept modest
        # so it can't starve the kernel's own RT threads. (Same reasoning the old spotifyd used.)
        CPUSchedulingPolicy = "fifo";
        CPUSchedulingPriority = 5;
        LimitRTPRIO = 50;
        LimitRTTIME = "infinity";
      };
    };

    # --- REALTIME SCHEDULING & CPU GOVERNOR (XRUN insurance) ---
    # Pin the governor so cores don't down-clock mid-stream and starve the audio thread.
    # Trade-off: higher idle power/heat on this fanless box — consistent with holding the
    # clock open 24/7. mkDefault so a host can opt back to `ondemand`.
    powerManagement.cpuFreqGovernor = lib.mkDefault "performance";

    # --- FIREWALL ---
    # Two trust boundaries:
    #  * LAN — only Spotify Connect discovery (so the phone on wifi sees "porcupineFish"):
    #    mDNS + librespot's pinned zeroconf TCP port. Nothing else is exposed on the LAN.
    #  * tailscale0 — snapserver control (1705) + snapweb (1780) + the range of dynamic TCP
    #    ports Music Assistant tells snapserver to open for its pushed audio streams. MA picks
    #    those ports at random (observed ~5000); tailscale0 is the trusted plane (same posture
    #    as Navidrome), so a range is acceptable. Widen if MA ever picks outside it.
    #  * 1704 (audio to the local snapclient) is loopback-bound — no rule at all.
    networking.firewall.allowedTCPPorts = [
      spotifyZeroconfPort # librespot zeroconf (Spotify Connect handshake) on the LAN
    ];
    networking.firewall.allowedUDPPorts = [
      5353 # mDNS — Spotify Connect discovery on the LAN
    ];
    networking.firewall.interfaces."tailscale0" = {
      allowedTCPPorts = [
        1705 # snapserver JSON-RPC control (Music Assistant on rk1b connects here)
        1780 # snapweb (manual stream switcher)
      ];
      allowedTCPPortRanges = [
        # Dynamic per-stream ports Music Assistant asks snapserver to open and pushes audio to.
        {
          from = 4000;
          to = 6000;
        }
      ];
    };
  };
}
