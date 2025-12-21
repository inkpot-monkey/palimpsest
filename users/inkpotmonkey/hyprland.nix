{ pkgs, ... }:

{
  # =========================================
  # Hyprland Base Configuration
  # =========================================
  wayland.windowManager.hyprland = {
    enable = true;
    systemd.enable = true; # Better session management

    settings = {
      # =========================================
      # 1. Output & Display
      # =========================================
      # 13.5" HiDPI Laptop Screen (2880x1920) -> Scale 1.6 = 1800x1200 effective
      monitor = [
        "eDP-1,2880x1920@120,0x0,1.6"
        ",preferred,auto,1" # Fallback for external monitors
      ];

      # Environment Variables
      env = [
        "XCURSOR_SIZE,24"
        "NIXOS_OZONE_WL,1" # Force Ozone Wayland
      ];

      # HiDPI Fixes
      xwayland = {
        force_zero_scaling = true; # Prevents fuzzy apps on HiDPI
      };

      # =========================================
      # 2. Startup Programs
      # =========================================
      exec-once = [
        # Session Bus Setup
        "dbus-update-activation-environment --systemd --all"
        
        # Core Services
        "swaync"                              # Notification Daemon
        "wl-paste --type text --watch cliphist store"  # Store text in history
        "wl-paste --type image --watch cliphist store" # Store images in history
        "wl-clip-persist --clipboard regular" # Keep clipboard content after app close
        "swayosd-server"                      # On-screen display server

        # Targeted Autostart
        "[workspace 1 silent] vivaldi"        # Browser on WS 1
        "[workspace 2 silent] emacsclient -c" # Editor on WS 2
      ];

      # =========================================
      # 3. Input & Devices
      # =========================================
      input = {
        kb_layout = "us";
        follow_mouse = 1;

        touchpad = {
          natural_scroll = false;
          scroll_factor = 0.5;
          clickfinger_behavior = true;
          tap-to-click = true;
        };

        sensitivity = 0; # -1.0 to 1.0
      };

      # Workspace gestures (v0.52+ syntax)
      gesture = [
        "3, horizontal, workspace"
      ];

      misc = {
        vfr = true; # Variable Frame Rate (power saving)
        vrr = 1;    # Variable Refresh Rate (1=on)
      };

      # =========================================
      # 4. Appearance & Layout
      # =========================================
      general = {
        gaps_in = 5;
        gaps_out = 10;
        border_size = 2;

        # Colors (Catppuccin Mocha themed gradient)
        "col.active_border" = "rgba(89b4faee) rgba(f38ba8ee) 45deg";
        "col.inactive_border" = "rgba(585b70aa)";

        layout = "dwindle";
      };

      decoration = {
        rounding = 10;
        active_opacity = 1.0;
        inactive_opacity = 0.9;

        blur = {
          enabled = true;
          size = 3;
          passes = 1;
        };

        shadow = {
          enabled = true;
          range = 4;
          render_power = 3;
          color = "rgba(1a1a1aee)";
        };
      };

      animations = {
        enabled = true;
        bezier = "myBezier, 0.05, 0.9, 0.1, 1.05";
        animation = [
          "windows, 1, 7, myBezier"
          "windowsOut, 1, 7, default, popin 80%"
          "border, 1, 10, default"
          "fade, 1, 7, default"
          "workspaces, 1, 6, default"
        ];
      };

      # =========================================
      # 5. Window Rules
      # =========================================
      windowrulev2 = [
        "float, title:^(emacs-launcher)$"
        "center, title:^(emacs-launcher)$"
        "size 60% 10%, title:^(emacs-launcher)$" # Modern compact launcher
        "dimaround, title:^(emacs-launcher)$"   # Focus effect
        "stayfocused, title:^(emacs-launcher)$"
      ];

      dwindle = {
        pseudotile = true;
        preserve_split = true;
      };

      # =========================================
      # 6. Keybindings
      # =========================================
      "$mod" = "SUPER";

      bind = [
        # Core Applications
        "$mod, Q, exec, kitty"
        "$mod, R, exec, wofi --show drun"       # Application Launcher
        "$mod, space, exec, emacsclient -cn -F '((name . \"emacs-launcher\") (minibuffer . only) (undecorated . t))' -e '(my/consult-omni-launcher)'"
        "$mod, E, exec, vivaldi"
        "$mod, N, exec, swaync-client -t -sw"  # Notifications center
        "$mod, L, exec, loginctl lock-session" # Screen lock

        # Window Operations
        "$mod SHIFT, M, exit,"                # Quit Hyprland
        "$mod, C, killactive,"                # Close window
        "$mod SHIFT, V, togglefloating,"      # Float window
        "$mod, V, exec, cliphist list | wofi --dmenu | cliphist decode | wl-copy" # Clipboard
        "$mod, F, fullscreen,"
        "$mod, P, pseudo,"                    # Dwindle pseudo-mode
        "$mod, J, togglesplit,"               # Dwindle split toggle

        # Navigation (Arrows & Vim)
        "$mod, left, movefocus, l"
        "$mod, right, movefocus, r"
        "$mod, up, movefocus, u"
        "$mod, down, movefocus, d"
        "$mod, h, movefocus, l"
        "$mod, l, movefocus, r"
        "$mod, k, movefocus, u"
        "$mod, j, movefocus, d"

        # Workspace Switching (1-0)
        "$mod, 1, workspace, 1"
        "$mod, 2, workspace, 2"
        "$mod, 3, workspace, 3"
        "$mod, 4, workspace, 4"
        "$mod, 5, workspace, 5"
        "$mod, 6, workspace, 6"
        "$mod, 7, workspace, 7"
        "$mod, 8, workspace, 8"
        "$mod, 9, workspace, 9"
        "$mod, 0, workspace, 10"

        # Window Repositioning
        "$mod SHIFT, 1, movetoworkspace, 1"
        "$mod SHIFT, 2, movetoworkspace, 2"
        "$mod SHIFT, 3, movetoworkspace, 3"
        "$mod SHIFT, 4, movetoworkspace, 4"
        "$mod SHIFT, 5, movetoworkspace, 5"
        "$mod SHIFT, 6, movetoworkspace, 6"
        "$mod SHIFT, 7, movetoworkspace, 7"
        "$mod SHIFT, 8, movetoworkspace, 8"
        "$mod SHIFT, 9, movetoworkspace, 9"
        "$mod SHIFT, 0, movetoworkspace, 10"

        # Hardware Buttons (Volume/Brightness)
        ", XF86AudioRaiseVolume, exec, swayosd-client --output-volume raise"
        ", XF86AudioLowerVolume, exec, swayosd-client --output-volume lower"
        ", XF86MonBrightnessUp, exec, swayosd-client --brightness raise"
        ", XF86MonBrightnessDown, exec, swayosd-client --brightness lower"

        # Screenshots
        ", Print, exec, grim -g \"$(slurp)\" - | wl-copy" # Region
        "SHIFT, Print, exec, grim - | wl-copy"           # Screen
      ];

      # Extra Multimedia & Switches (Locked state support)
      bindl = [
        ", XF86AudioMute, exec, swayosd-client --output-volume mute-toggle"
        ", XF86AudioMicMute, exec, swayosd-client --input-volume mute-toggle"
        ", XF86AudioPlay, exec, playerctl play-pause"
        ", XF86AudioNext, exec, playerctl next"
        ", XF86AudioPrev, exec, playerctl previous"
        ", XF86RFKill, exec, rfkill toggle all" # Airplane mode
        ", switch:on:Lid Switch, exec, systemctl suspend"
      ];

      # Mouse Interactions
      bindm = [
        "$mod, mouse:272, movewindow"
        "$mod, mouse:273, resizewindow"
      ];
    };
  };
}
