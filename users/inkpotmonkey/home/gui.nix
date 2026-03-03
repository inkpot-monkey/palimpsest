{
  pkgs,
  config,
  lib,
  ...
}:

{

  config = lib.mkIf (config.identity.profile == "gui") {
    services.poweralertd.enable = true;

    xdg.portal = {
      enable = true;
      extraPortals = [ pkgs.xdg-desktop-portal-gtk ]; # standard fallback
      config = {
        common = {
          default = [ "gtk" ];
          "org.freedesktop.impl.portal.Settings" = [ "darkman" ];
        };
      };
    };

    # ==========================================
    # Environment Variables
    # ==========================================
    home.sessionVariables = {
      BROWSER = "vivaldi";
      # Ensure Hyprland apps use Wayland
      NIXOS_OZONE_WL = "1";
    };

    # ==========================================
    # Core UI Components
    # ==========================================

    # 1. Terminal
    programs.kitty = {
      enable = true;
      themeFile = "Catppuccin-Mocha";
      settings = {
        font_size = 12;
        confirm_os_window_close = 0;
      };
    };

    # 2. Launcher
    programs.wofi.enable = true;

    # 5. GTK Theme & Icons
    gtk = {
      enable = true;
      theme = {
        name = "Catppuccin-Mocha-Standard-Blue-Dark";
        package = pkgs.catppuccin-gtk.override {
          accents = [ "blue" ];
          size = "standard";
          tweaks = [ "rimless" ];
          variant = "mocha";
        };
      };
      iconTheme = {
        name = "Papirus-Dark";
        package = pkgs.catppuccin-papirus-folders.override {
          flavor = "mocha";
          accent = "blue";
        };
      };
    };

    # 6. Cursor Theme
    home.pointerCursor = {
      gtk.enable = true;
      x11.enable = true;
      name = "catppuccin-mocha-dark-cursors";
      package = pkgs.catppuccin-cursors.mochaDark;
      size = 24;
    };

    # ==========================================
    # Configured Programs
    # ==========================================

    # MPV with plugins and high-quality settings
    programs.mpv = {
      enable = true;
      package = pkgs.mpv.override {
        scripts = [
          pkgs.mpvScripts.modernz
          pkgs.mpvScripts.mpvacious
        ];
      };
      config = {
        profile = "high-quality";
        ytdl-format = "bestvideo+bestaudio";
        cache-default = 4000000;
      };
    };

    # ==========================================
    # User Packages
    # ==========================================
    home.packages = with pkgs; [
      ocr-shot

      # --- Fonts ---
      recursive
      montserrat
      libre-caslon

      # --- System Utilities ---
      brightnessctl
      playerctl
      grim
      slurp
      swayosd # OSD for volume/brightness

      # --- Shell tools ---
      to-av1

      # --- Internet & Browsers ---
      google-chrome
      brave

      # Main browser
      (vivaldi.override {
        proprietaryCodecs = true;
        enableWidevine = true;
      })
      # Also add this specifically for video playback support
      vivaldi-ffmpeg-codecs

      qbittorrent-enhanced
      pritunl-client
      protonvpn-gui

      # --- Communication ---
      # vesktop # Discord client
      signal-desktop
      slack
      zulip
      zoom-us
      beeper

      # --- Development ---
      postman
      beekeeper-studio
      distrobox
      quickemu
      nss_latest # Cert tools

      # --- Media & Creativity ---
      spotify
      gimp3
      blender
      ffmpeg
      yt-dlp
      youtube-tui

      # --- AI & Audio Processing ---
      whisper-cpp
      deepfilternet

      # --- System & Utilities ---
      wl-clipboard # Clipboard manager (Essential for Hyprland)
      wl-clip-persist # Clipboard persistence
      # cliphist # Clipboard history service (Managed by Home Manager)
      kdePackages.polkit-kde-agent-1 # GUI Authentication Agent
      ledger-live-desktop
      anki-bin

      # --- Themes (Latte for Light Mode) ---
      (pkgs.catppuccin-gtk.override {
        accents = [ "blue" ];
        size = "standard";
        tweaks = [ "rimless" ];
        variant = "latte";
      })
    ];

    # ==========================================
    # 6.5 Hyprpaper (Wallpaper)
    # ==========================================
    services.hyprpaper = {
      enable = true;
      settings = {
        ipc = "on";
        splash = false;
        preload = [ "${./assets/wallpaper.png}" ];
        wallpaper = [ ",${./assets/wallpaper.png}" ];
      };
    };

    # ==========================================
    # 6.6 Polkit Authentication Agent
    # ==========================================
    systemd.user.services.polkit-agent = {
      Unit = {
        Description = "Polkit Authentication Agent";
        WantedBy = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.kdePackages.polkit-kde-agent-1}/libexec/polkit-kde-authentication-agent-1";
        Restart = "on-failure";
        RestartSec = 1;
        TimeoutStopSec = 10;
      };
    };

    # ==========================================
    # 7. Automatic Dark/Light Mode
    # ==========================================
    services.darkman = {
      enable = true;
      settings = {
        # lat = 41.38; # Update with your coords
        # lng = 2.16; # Update with your coords
        # usegeoclue = true; # Set to true if you use Geoclue service
      };

      # Script to run when switching to DARK mode
      darkModeScripts = {
        gtk-theme = ''
          ${pkgs.glib}/bin/gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
          # ${pkgs.glib}/bin/gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark'
        '';

        # Optional: Change Hyprland border colors
        hyprland-borders = ''
          ${pkgs.hyprland}/bin/hyprctl keyword general:col.active_border "0xffa7c080"
        '';
      };

      # Script to run when switching to LIGHT mode
      lightModeScripts = {
        gtk-theme = ''
          ${pkgs.glib}/bin/gsettings set org.gnome.desktop.interface color-scheme 'prefer-light'
          # ${pkgs.glib}/bin/gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita'
        '';

        # Optional: Change Hyprland border colors back
        hyprland-borders = ''
          ${pkgs.hyprland}/bin/hyprctl keyword general:col.active_border "0xff595959"
        '';
      };
    };

    # ==========================================
    # 8. Clipboard History
    # ==========================================
    services.cliphist = {
      enable = true;
      allowImages = true;
    };

    # =========================================
    # XDG & Application Defaults
    # =========================================
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
  };
}
