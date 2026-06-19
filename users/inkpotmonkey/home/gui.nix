{
  pkgs,
  config,
  inputs,
  lib,
  ...
}:
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
    home.packages = with pkgs; [
      # --- Fonts ---
      recursive
      montserrat
      libre-caslon

      # --- Internet & Browsers ---
      google-chrome
      brave
      slack
      signal-desktop
      zulip
      zoom-us
      beeper

      # Main browser
      (vivaldi.override {
        proprietaryCodecs = true;
        enableWidevine = true;
      })
      vivaldi-ffmpeg-codecs

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
      # Claude Desktop (community Linux repackaging; no official Linux build)
      inputs.claude-desktop.packages.${pkgs.stdenv.hostPlatform.system}.claude-desktop
      ocr-shot
      anki-bin
      whisper-cpp
      deepfilternet
      playerctl
      wl-clipboard
      wl-clip-persist
      brightnessctl
    ];
  };
}
