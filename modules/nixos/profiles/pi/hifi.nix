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

  # The stream-switcher arbiter (auto-follow the active source + volume reference). See
  # snapcast-stream-switcher.py and the `--volume-ctrl` note below. (#96)
  streamSwitcher = ./snapcast-stream-switcher.py;

  # librespot's volume cache. snapserver passes `&cache=` straight through as librespot's
  # `--cache`, which is also where librespot keeps its `volume` file (main.rs: the volume dir is
  # `--system-cache` or, failing that, `--cache`). Paired with `&disable_audio_cache=true` and
  # `--disable-credential-cache` in `&params`, this directory holds exactly one thing — the last
  # volume the Spotify app asked for. No audio chunks, no Spotify token on disk. CacheDirectory
  # on the snapserver unit below creates it; it lives on the ephemeral root by design (see
  # hosts/porcupineFish/impermanence.nix), so a reboot returns to the default below.
  librespotCache = "/var/cache/snapserver/librespot";

  # The volume librespot starts at when that cache is empty — first run, and every boot.
  # librespot's scale is 0..u16::MAX, and this is the value `--initial-volume 50` would have
  # computed (50/100 × 65535), i.e. half-scale on the slider: (0.9·0.5 + 0.1)³ = −15.6 dB.
  librespotDefaultVolume = 32767;

  # The stream name the Spotify librespot source registers under, and the snapclient hostID.
  # Shared between the librespot source and the switcher's reference-volume config so the two
  # agree on which stream is app-controlled.
  spotifyStream = "Spotify";
  snapclientId = "porcupineFish";

  # Spotify becomes a snapserver `librespot` stream instead of a standalone daemon
  # (spotifyd can't feed snapserver — no pipe backend; snapserver runs `librespot
  # --backend pipe` itself, the clean path Volumio uses). Zeroconf mode: no stored
  # credentials, the phone hands off the session. `devicename` is what shows in the
  # Spotify app; `name` is the snapcast stream/tab name. `params` passes raw args through
  # to librespot. (ADR-0031, #96)
  #
  # VOLUME — the Spotify APP slider must work, so librespot's *own* volume is Spotify's
  # control: `--volume-ctrl cubic` gives a natural, full-range curve that the phone slider
  # drives directly (librespot 0.8's pipe backend can't report the app's volume *without*
  # also attenuating, so bridging the slider onto the shared hardware mixer would
  # double-attenuate — verified in spirc.rs `set_volume`; see #96). The cost: Spotify's gain
  # is now digital (academic for a lossy 320k source) and independent of MA's volume, rather
  # than one shared hardware master. To stop Spotify inheriting the low level MA may have left
  # on the shared snapclient mixer, the switcher pins that mixer to a reference (100%) on every
  # switch to this stream (SWITCHER_REFERENCE_* below) — so the app slider is the only gain
  # that then varies.
  #
  # `volume=` is deliberately EMPTY, and that is the whole fix for "Spotify drops out and comes
  # back deafening". An empty value makes snapserver omit `--initial-volume` altogether
  # (librespot_stream.cpp: `if (!volume.empty()) params_ += " --initial-volume " + volume`),
  # which matters because:
  #   * librespot re-applies its initial volume to the mixer on *every* Spirc creation
  #     (spirc.rs `Spirc::new` → `set_volume`), and main.rs re-creates the Spirc after every
  #     "Spirc shut down unexpectedly" — i.e. after every dropped Spotify session; and
  #   * an explicit `--initial-volume` *overrides* the remembered one (main.rs:
  #     `opt_str(INITIAL_VOLUME).map(…).or_else(|| cache.volume())`).
  # So with a fixed initial volume, any wifi blip resets the gain to whatever that number is.
  # From a typical 25% app slider — cubic (0.9·0.25 + 0.1)³ = −29 dB — a reconnect used to be
  # +29 dB louder, which is how a websocket reset became a jump to full scale. With the cache
  # instead, a reconnect restores the level the app last set, and `librespotDefaultVolume`
  # applies only when there is nothing to restore.
  librespotSource = lib.concatStrings [
    "librespot:///${lib.getExe pkgs.librespot}"
    "?name=${spotifyStream}"
    "&devicename=porcupineFish"
    "&bitrate=320"
    "&normalize=true"
    # Empty on purpose — see the VOLUME note above. Do not give this a value.
    "&volume="
    # Remember the app's volume across session drops and librespot restarts.
    "&cache=${librespotCache}"
    "&disable_audio_cache=true"
    # snapcast forbids `--onevent` in &params (use &onevent) but passes everything else
    # through verbatim. Keep the pinned zeroconf port so the firewall can open exactly it.
    # `--disable-credential-cache` keeps the cache above volume-only: zeroconf hands the
    # session over per-connect, so there is no reason to leave Spotify credentials on disk.
    "&params=--volume-ctrl cubic --zeroconf-port ${toString spotifyZeroconfPort} --disable-credential-cache"
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

    # snapserver's unit needs two things the nixpkgs module does not give it.
    systemd.services.snapserver = {
      # 1. A network with an actual address. librespot's zeroconf needs a non-loopback
      #    interface; with none up, libmdns fails ("Setting up dns-sd failed: No such device"),
      #    librespot treats a dead discovery as fatal (`Discovery stopped unexpectedly` →
      #    exit(1)) and snapserver respawns it — measured at 67-93 restarts on every boot,
      #    looping until NetworkManager finished associating, each one re-advertising and then
      #    withdrawing the Connect device. The module only orders after `network.target`, which
      #    says nothing about addresses, so wait for the real thing. (NetworkManager-wait-online
      #    backs this target on this host — see the wireless profile.)
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        # 2. Somewhere for librespot to remember the app's volume. Ephemeral on purpose — it is
        #    the level, not an audio cache, and losing it just means starting from
        #    `librespotDefaultVolume` again.
        CacheDirectory = "snapserver";

        # Seed the default volume, so the first connect after a boot lands on a level this repo
        # chose rather than on whatever librespot happens to default to. librespot creates this
        # directory itself (cache.rs `Cache::new`), but only once snapserver has started it —
        # too late to write the file into, hence the mkdir here. Runs as the unit's own
        # (dynamic) user, so the file ends up owned correctly. `-` prefixed: seeding a volume
        # must never be able to keep the audio node down.
        ExecStartPre = [
          "-${pkgs.writeShellScript "librespot-seed-volume" ''
            set -eu
            mkdir -p ${librespotCache}
            if [ ! -e ${librespotCache}/volume ]; then
              echo ${toString librespotDefaultVolume} > ${librespotCache}/volume
            fi
          ''}"
        ];
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
          "--hostID ${snapclientId}"
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

    # --- STREAM-SWITCHER (auto-follow the active source) ---
    # snapclient plays whichever stream its group is bound to, and snapcast 0.34 does NOT
    # auto-follow: hit play in the *other* source and the group stays put → silence (#96).
    # This watcher subscribes to snapserver's control API (Stream.OnUpdate) and, on a
    # debounced idle→playing edge, Group.SetStream's the connected client's group to the
    # stream that just started — so playing in either the Spotify app or Music Assistant
    # "just works" with no manual switch. Event-driven off stream *status* (not PCM
    # sniffing) and debounced so a between-tracks idle dip never flaps the output. It also
    # pins the shared hardware mixer to a reference on switch to Spotify, whose volume lives
    # in the app slider (SWITCHER_REFERENCE_* below) — see the librespot volume note above.
    systemd.services.snapcast-stream-switcher = {
      description = "Auto-follow the active Snapcast stream (Volumio-style arbiter)";
      wantedBy = [ "multi-user.target" ];
      after = [ "snapserver.service" ];
      wants = [ "snapserver.service" ];
      serviceConfig = {
        # It only speaks to snapserver over loopback :1705 and drives no hardware, so run it
        # locked-down as its own dynamic, unprivileged user.
        ExecStart = "${lib.getExe pkgs.python3} ${streamSwitcher}";
        Restart = "always";
        RestartSec = 5;
        DynamicUser = true;
        # Reach snapserver over the loopback control port only; no other network, no devices.
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        IPAddressAllow = "localhost";
        IPAddressDeny = "any";
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
      };
      environment = {
        SNAPCAST_HOST = "127.0.0.1";
        SNAPCAST_PORT = "1705";
        # The snapclient --hostID; its group is the one we route.
        SWITCHER_CLIENT_ID = snapclientId;
        SWITCHER_DEBOUNCE_SEC = "5";
        # Tie-break only (startup / both playing at once); last-activated-wins otherwise.
        SWITCHER_PRIORITY = spotifyStream;
        # Spotify's volume is the app slider (librespot's own control), so pin the shared
        # hardware mixer to full whenever we route to it — otherwise Spotify inherits the low
        # level MA last left on that mixer and the app slider can't recover it (#96).
        SWITCHER_REFERENCE_STREAM = spotifyStream;
        SWITCHER_REFERENCE_PERCENT = "100";
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
