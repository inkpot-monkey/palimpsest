{
  pkgs,
  config,
  inputs,
  lib,
  ...
}:
let
  vivaldiBase = pkgs.vivaldi.override {
    proprietaryCodecs = true;
    enableWidevine = true;
  };

  # Wraps Vivaldi with --remote-debugging-port=0 so Chromium writes the
  # allocated port to ~/.config/vivaldi/DevToolsActivePort each launch.
  # The .desktop Exec lines are patched to use the wrapper binary so that
  # MIME launches and taskbar pins also get the flag.
  vivaldiWithCdp = pkgs.symlinkJoin {
    name = "vivaldi-cdp";
    paths = [ vivaldiBase ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram "$out/bin/vivaldi" \
        --add-flags "--remote-debugging-port=0"
      desktop="$out/share/applications/vivaldi-stable.desktop"
      cp --remove-destination "$(readlink -f "$desktop")" "$desktop"
      substituteInPlace "$desktop" \
        --replace-fail "${vivaldiBase}/bin/vivaldi" "$out/bin/vivaldi"
    '';
  };

  # Samples renderer RSS and CDP tab list every 30 s; appends JSONL to
  # ~/.local/share/vivaldi-memlog/YYYY-MM-DD.jsonl. Exits immediately when
  # no Vivaldi renderer processes are alive. Rotates files older than 30 d.
  vivaldiMemlog = pkgs.writeShellApplication {
    name = "vivaldi-memlog";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
      pkgs.procps
      pkgs.gawk
    ];
    text = ''
      LOG_DIR="$HOME/.local/share/vivaldi-memlog"
      mkdir -p "$LOG_DIR"

      mapfile -t renderer_pids < <(pgrep -f 'vivaldi-bin --type=renderer' || true)
      [[ ''${#renderer_pids[@]} -eq 0 ]] && exit 0

      TIMESTAMP=$(date -Iseconds)
      LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d).jsonl"

      renderers_json=$(
        for pid in "''${renderer_pids[@]}"; do
          rss=$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null || true)
          [[ -n "$rss" ]] && printf '{"pid":%s,"rss_kb":%s}\n' "$pid" "$rss"
        done | jq -s '.'
      )

      tabs_json="null"
      cdp_port_file="$HOME/.config/vivaldi/DevToolsActivePort"
      if [[ -f "$cdp_port_file" ]]; then
        cdp_port=$(head -1 "$cdp_port_file")
        tabs_raw=$(curl -sf --max-time 2 "http://localhost:''${cdp_port}/json" 2>/dev/null || true)
        if [[ -n "$tabs_raw" ]]; then
          tabs_json=$(jq '[.[] | {id, type, title, url}]' <<< "$tabs_raw" 2>/dev/null || echo "null")
        fi
      fi

      printf '{"ts":"%s","renderers":%s,"tabs":%s}\n' \
        "$TIMESTAMP" "$renderers_json" "$tabs_json" >> "$LOG_FILE"

      find "$LOG_DIR" -name '*.jsonl' -mtime +30 -delete 2>/dev/null || true
    '';
  };

  # The "Operator read" path onto the Stash (CONTEXT.md → Secrets). Factored into
  # ./secret.nix so parts/checks/secret-read can exercise the real derivation; the
  # rationale (why it names sops, working-tree-not-deployed, gui-scoping) lives there.
  secret = import ./secret.nix {
    inherit pkgs;
    inherit (config.identity) username;
    homeDirectory = config.home.homeDirectory;
  };
in
{
  config = lib.mkIf config.custom.home.profiles.gui.enable {
    # ==========================================
    # Environment Variables
    # ==========================================
    home.sessionVariables = {
      BROWSER = "vivaldi";
      # Ensure Electron apps use Wayland
      NIXOS_OZONE_WL = "1";
    };

    programs.google-chrome.enable = true;

    # ==========================================
    # Core UI Components
    # ==========================================
    programs.kitty = {
      enable = true;
      themeFile = "Catppuccin-Mocha";
      settings = {
        font_size = 12;
        confirm_os_window_close = 0;
      };
    };

    # ==========================================
    # XDG & Application Defaults
    # ==========================================
    xdg.userDirs = {
      enable = true;
      createDirectories = true;
      # Keep legacy behavior (export XDG_*_DIR session variables); the default
      # flipped to false for stateVersion >= 26.05.
      setSessionVariables = true;
    };

    xdg.mimeApps = {
      enable = pkgs.stdenv.isLinux;
      defaultApplications = {
        "text/html" = [
          "vivaldi.desktop"
          "vivaldi-stable.desktop"
        ];
        "x-scheme-handler/mailto" = [
          "vivaldi.desktop"
          "vivaldi-stable.desktop"
        ];
        "x-scheme-handler/http" = [
          "vivaldi.desktop"
          "vivaldi-stable.desktop"
        ];
        "x-scheme-handler/https" = [
          "vivaldi.desktop"
          "vivaldi-stable.desktop"
        ];
        "x-scheme-handler/about" = [
          "vivaldi.desktop"
          "vivaldi-stable.desktop"
        ];
        "x-scheme-handler/unknown" = [
          "vivaldi.desktop"
          "vivaldi-stable.desktop"
        ];
      };
    };
    xdg.configFile."mimeapps.list".force = true;

    # ==========================================
    # User Packages
    # ==========================================
    home.packages =
      with pkgs;
      [
        # --- Fonts ---
        recursive
        montserrat
        libre-caslon

        # --- Internet & Browsers ---
        brave
        slack
        signal-desktop
        zulip
        zoom-us
        beeper

        # Main browser — CDP-wrapped build enables per-renderer memory logging
        vivaldiWithCdp
        vivaldi-ffmpeg-codecs
        vivaldiMemlog

        qbittorrent-enhanced
        pritunl-client
        proton-vpn

        # --- Development & System ---
        postman
        beekeeper-studio
        distrobox
        quickemu
        nss_latest # Cert tools
        ledger-live-desktop

        # --- Media & Creativity ---
        spotify
        gimp3
        blender
        ffmpeg
        yt-dlp
        mpv

        # --- Utilities & AI ---
        # Claude Desktop + Cowork (community Linux repackaging; no official Linux
        # build). Runs Cowork skills natively under bubblewrap — see the
        # claude-cowork-linux input comment in flake.nix.
        #
        # NixOS gotcha: Cowork's exec registry resolves the Claude CLI and system
        # tools (bash, git, curl, …) only from fixed FHS/dotfile paths, never
        # $PATH. Two pieces outside this package are REQUIRED, or tasks die with
        # "bash not found" / exit code 127:
        #   - host: services.envfs.enable + git/libnotify/glib in systemPackages
        #           (hosts/sawtoothShark/configuration.nix)
        #   - user: the native claude CLI symlinked into ~/.local/bin
        #           (../ai/default.nix)
        inputs.claude-cowork-linux.packages.${pkgs.stdenv.hostPlatform.system}.claude-cowork-linux
        ocr-shot
        anki-bin
        whisper-cpp
        deepfilternet
        playerctl
        wl-clipboard
        wl-clip-persist
        brightnessctl
      ]
      ++ [ secret ]; # Operator read onto the Stash (see the let-binding above)

    # ==========================================
    # Vivaldi renderer memory sampler
    # ==========================================
    systemd.user.services.vivaldi-memlog = {
      Unit = {
        Description = "Sample Vivaldi renderer memory and CDP tab list";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${vivaldiMemlog}/bin/vivaldi-memlog";
      };
    };

    systemd.user.timers.vivaldi-memlog = {
      Unit.Description = "Periodically sample Vivaldi renderer memory";
      Timer = {
        OnActiveSec = "30s";
        OnUnitActiveSec = "30s";
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
