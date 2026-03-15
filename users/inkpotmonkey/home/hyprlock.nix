{
  config,
  lib,
  ...
}:
{
  options.custom.home.profiles.hyprlock = {
    enable = lib.mkEnableOption "Hyprlock screen locker";
  };

  config = lib.mkIf config.custom.home.profiles.hyprlock.enable {
    # ============================================================================
    # Hyprlock - The Modern Lock Screen
    # ============================================================================
    programs.hyprlock = {
      enable = true;
      settings = {
        general = {
          disable_loading_bar = true;
          hide_cursor = true;
          no_fade_in = false;
        };

        background = [
          {
            path = "screenshot"; # Use blurred screenshot of current screen
            blur_passes = 3;
            blur_size = 8;
          }
        ];

        input-field = [
          {
            size = "200, 50";
            position = "0, -80";
            monitor = "";
            dots_center = true;
            fade_on_empty = false;
            font_color = "rgb(202, 211, 245)";
            inner_color = "rgb(30, 30, 46)";
            outer_color = "rgb(24, 24, 37)";
            outline_thickness = 5;
            placeholder_text = "Password...";
            shadow_passes = 2;
          }
        ];

        label = [
          # Clock
          {
            monitor = "";
            text = "cmd[update:1000] echo \"$TIME\"";
            color = "rgb(202, 211, 245)";
            font_size = 55;
            font_family = "JetBrains Mono Nerd Font ExtraBold";
            position = "0, 300";
            halign = "center";
            valign = "center";
            shadow_passes = 2;
          }
          # Greeting
          {
            monitor = "";
            text = "Hi, inkpotmonkey";
            color = "rgb(202, 211, 245)";
            font_size = 20;
            font_family = "JetBrains Mono Nerd Font Bold";
            position = "0, 240";
            halign = "center";
            valign = "center";
            shadow_passes = 2;
          }
        ];
      };
    };

    # ============================================================================
    # Hypridle - Idle Daemon
    # ============================================================================
    services.hypridle = {
      enable = true;
      settings = {
        general = {
          lock_cmd = "pidof hyprlock || hyprlock"; # dbus/sysd lock command
          before_sleep_cmd = "loginctl lock-session"; # lock before suspend.
          after_sleep_cmd = "hyprctl dispatch dpms on"; # to avoid having to press a key twice to turn on the display.
        };

        listener = [
          {
            timeout = 600; # 5min
            on-timeout = "loginctl lock-session"; # lock screen when timeout has passed
          }
          {
            timeout = 630; # 5.5min
            on-timeout = "hyprctl dispatch dpms off"; # screen off when timeout has passed
            on-resume = "hyprctl dispatch dpms on"; # screen on when activity is detected
          }
          {
            timeout = 1800; # 30min
            on-timeout = "systemctl suspend"; # suspend pc
          }
        ];
      };
    };
  };
}
