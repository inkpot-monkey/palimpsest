{
  config,
  lib,
  pkgs,
  self,
  ...
}:

let
  cfg = config.custom.profiles.hifi;
in
{
  options.custom.profiles.hifi = {
    enable = lib.mkEnableOption "High-fidelity audio (Spotifyd) configuration for Raspberry Pi";
  };

  config = lib.mkIf cfg.enable {
    # --- AUDIO STACK (ALSA Direct) ---
    services.pulseaudio.enable = false;

    hardware.alsa.enablePersistence = true;

    # --- PACKAGES ---
    environment.systemPackages = with pkgs; [
      alsa-utils
    ];

    # --- SECRETS ---
    sops.secrets."spotify/password" = {
      sopsFile = self.lib.getSecretPath "profiles/media.yaml";
      owner = "spotifyd";
      group = "spotifyd";
    };

    # --- USERS for SOPS ---
    users.users.spotifyd = {
      isSystemUser = true;
      group = "spotifyd";
      extraGroups = [ "audio" ];
    };
    users.groups.spotifyd = { };

    # --- SERVICES ---
    services.spotifyd = {
      enable = true;
      settings = {
        global = {
          username = "ch0p_";
          password_cmd = "cat ${config.sops.secrets."spotify/password".path}";
          backend = "alsa";
          device = "hw:sndrpihifiberry";
          # Drive the PCM512x's hardware "Digital" mixer with a dB-aware curve.
          # WITHOUT volume_controller = "alsa", spotifyd silently falls back to its
          # *software* controller (logged as `softvol ... Log(60.0)`): a 60 dB curve
          # that sits near-silent until ~70% of the slider, and attenuates digitally
          # (bit-depth loss). "alsa" maps the slider across the DAC's real dB range
          # instead — a human-centric curve at full fidelity. `mixer` is only
          # honoured once the controller is "alsa"; on its own it was a no-op.
          volume_controller = "alsa";
          # In spotifyd 0.4.2 these keys are the reverse of what `--help`'s terse
          # labels imply: `mixer` is the ALSA *control device* (which card to
          # open) and `control` is the *name* of the simple mixer element on it.
          # The PCM512x's hardware volume element is "Digital".
          control = "Digital";
          mixer = "default:CARD=sndrpihifiberry";
          bitrate = 320;
          cache_path = "/var/cache/spotifyd";
          volume_normalisation = true;
          normalisation_pregain = 0; # Increased from -10 to boost volume
          device_type = "speaker";
          device_name = "porcupineFish";
          zeroconf_port = 5354; # Use fixed port for mDNS discovery (not 5353)
          use_mpris = false; # Disable MPRIS to avoid D-Bus crashes on headless system
        };
      };
    };

    # --- DISCONNECT WATCHDOG ---
    # spotifyd silently loses its connection to Spotify's backend (websocket reset)
    # but the *process never exits*, so it lingers "active (running)" while vanishing
    # from Spotify Connect — you can no longer reach it from the app. systemd's
    # Restart=always can't help: there's no exit to react to. This is an upstream
    # wontfix (Spotifyd/spotifyd#586, #458, #1154); the only remedy is an external
    # restart. We tail spotifyd's journal and bounce it on the one marker that
    # reliably precedes a wedge — `unexpected shutdown` (the session teardown).
    # By the time it's logged the session is already gone, so a restart here recovers
    # the wedge without interrupting healthy playback. The noisier `Websocket peer
    # does not respond` / `Connection to server closed` lines usually self-recover,
    # so we deliberately do NOT trigger on them.
    systemd.services.spotifyd-watchdog = {
      description = "Restart spotifyd when it silently loses its Spotify connection";
      wantedBy = [ "multi-user.target" ];
      after = [ "spotifyd.service" ];
      wants = [ "spotifyd.service" ];
      serviceConfig = {
        Restart = "always";
        RestartSec = 5;
        # Persists the wedge-restart counter across watchdog restarts/reboots.
        StateDirectory = "spotifyd-watchdog";
        ExecStart = pkgs.writeShellScript "spotifyd-watchdog" ''
          set -uo pipefail

          state="$STATE_DIRECTORY/restarts"
          # Already created (mode 0775) by the node-exporter textfile collector
          # profile; the textfile collector picks up *.prom written here.
          prom="/var/lib/prometheus-node-exporter-text-files/spotifyd_watchdog.prom"

          # Follow spotifyd's journal from *now* (-n0), raw message text only.
          ${pkgs.systemd}/bin/journalctl -n0 -f -o cat -u spotifyd.service \
            | while IFS= read -r line; do
                case "$line" in
                  *"unexpected shutdown"*)
                    echo "wedge detected ('unexpected shutdown') -> restarting spotifyd" >&2
                    ${pkgs.systemd}/bin/systemctl restart spotifyd.service

                    # Bump a node-exporter textfile metric so the existing scrape
                    # makes this visible in VictoriaMetrics/Grafana. Atomic write.
                    n=$(${pkgs.coreutils}/bin/cat "$state" 2>/dev/null || echo 0)
                    n=$((n + 1))
                    echo "$n" > "$state"
                    ts=$(${pkgs.coreutils}/bin/date +%s)
                    {
                      echo "# HELP spotifyd_watchdog_restarts_total Restarts triggered by the spotifyd disconnect watchdog."
                      echo "# TYPE spotifyd_watchdog_restarts_total counter"
                      echo "spotifyd_watchdog_restarts_total $n"
                      echo "# HELP spotifyd_watchdog_last_restart_timestamp_seconds Unix time of the last watchdog-triggered restart."
                      echo "# TYPE spotifyd_watchdog_last_restart_timestamp_seconds gauge"
                      echo "spotifyd_watchdog_last_restart_timestamp_seconds $ts"
                    } > "$prom.tmp" && ${pkgs.coreutils}/bin/mv "$prom.tmp" "$prom"

                    # Let the fresh connection settle; avoids re-triggering on the
                    # restart's own startup chatter and rate-limits restart storms.
                    ${pkgs.coreutils}/bin/sleep 60
                    ;;
                esac
              done
        '';
      };
    };

    # --- FIREWALL ---
    # Open ports for Spotify Connect discovery (mDNS) and streaming
    networking.firewall.allowedTCPPorts = [
      5354 # Spotifyd zeroconf
    ];
    networking.firewall.allowedUDPPorts = [
      5353 # mDNS broadcast
      5354 # Spotifyd zeroconf
    ];
  };
}
