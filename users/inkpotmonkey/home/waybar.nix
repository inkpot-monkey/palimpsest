{
  config,
  lib,
  ...
}:
{
  options.custom.home.profiles.waybar = {
    enable = lib.mkEnableOption "Waybar status bar";
  };

  config = lib.mkIf config.custom.home.profiles.waybar.enable {
    # =========================================
    # Waybar Configuration
    # =========================================
    programs.waybar = {
      enable = true;
      systemd.enable = true; # Autostart via systemd user session

      # =========================================
      # Visual Styling (CSS)
      # =========================================
      style = ''
        * {
          border: none;
          border-radius: 0;
          font-family: "JetBrainsMono Nerd Font", Roboto, Helvetica, Arial, sans-serif;
          font-size: 13px;
          min-height: 0;
        }

        window#waybar {
          background: transparent;
          color: #cdd6f4;
        }

        /* Workspaces Module */
        #workspaces {
          background: #1e1e2e;
          margin: 5px;
          padding: 0 5px;
          border-radius: 16px;
          border: 1px solid #181825;
        }

        #workspaces button {
          padding: 0 5px;
          background: transparent;
          color: #cdd6f4;
          border-radius: 16px;
        }

        #workspaces button.active {
          color: #1e1e2e;
          background: #cba6f7; /* Mauve accent */
        }

        #workspaces button:hover {
          background: #313244;
        }

        /* Base Modules Style */
        #clock,
        #battery,
        #cpu,
        #memory,
        #network,
        #pulseaudio,
        #tray {
          background: #1e1e2e;
          color: #cdd6f4;
        }

        /* Window Title */
        #window {
          background: #1e1e2e;
          color: #cdd6f4;
          border-radius: 16px;
          margin: 5px;
          padding: 0 10px;
          border: 1px solid #181825;
        }

        /* Center Clock */
        #clock {
          background-color: #1e1e2e;
          border-radius: 16px;
          margin: 5px 10px;
          padding: 2px 20px;
          border: 1px solid #181825;
          font-weight: bold;
          color: #89b4fa; /* Blue accent */
        }

        /* Right Module Group (System status) */
        #pulseaudio {
          color: #89b4fa; /* Blue */
          border-radius: 16px 0 0 16px;
          margin: 5px 0 5px 10px;
          padding: 0 10px;
          border: 1px solid #181825;
          border-right: none;
        }

        #network {
          color: #f9e2af; /* Yellow */
          border-top: 1px solid #181825;
          border-bottom: 1px solid #181825;
          padding: 0 10px;
          margin: 5px 0;
        }

        #battery {
          color: #a6e3a1; /* Green */
          border-radius: 0 16px 16px 0;
          margin: 5px 10px 5px 0;
          padding: 0 10px;
          border: 1px solid #181825;
          border-left: none;
        }

        #battery.charging, #battery.plugged {
          color: #a6e3a1;
        }

        #battery.critical:not(.charging) {
          background-color: #f38ba8; /* Red urgency */
          color: #1e1e2e;
          animation-name: blink;
          animation-duration: 0.5s;
          animation-timing-function: linear;
          animation-iteration-count: infinite;
          animation-direction: alternate;
        }

        #tray {
          border-radius: 16px;
          margin: 5px 10px;
          padding: 0 10px;
          border: 1px solid #181825;
        }
      '';

      # =========================================
      # Bar Settings & Layout
      # =========================================
      settings = {
        mainBar = {
          layer = "top";
          position = "top";
          height = 36;
          spacing = 0;

          modules-left = [
            "hyprland/workspaces"
            "hyprland/window"
          ];

          modules-center = [
            "clock"
          ];

          modules-right = [
            "pulseaudio"
            "network"
            "battery"
            "tray"
          ];

          # =========================================
          # Module Configurations
          # =========================================
          "hyprland/workspaces" = {
            disable-scroll = true;
            all-outputs = true;
            on-click = "activate";
            format = "{name}";
          };

          "hyprland/window" = {
            max-length = 30;
            separate-outputs = true;
          };

          "clock" = {
            tooltip-format = "<big>{:%Y %B}</big>\n<tt><small>{calendar}</small></tt>";
            format-alt = "{:%Y-%m-%d}";
            format = "{:%a %d %b %H:%M}";
          };

          "pulseaudio" = {
            format = "{icon} {volume}%";
            format-bluetooth = "{icon} {volume}%";
            format-muted = " Muted";
            format-icons = {
              headphone = "";
              hands-free = "";
              headset = "";
              phone = "";
              portable = "";
              car = "";
              default = [
                ""
                ""
                ""
              ];
            };
            on-click = "pavucontrol";
          };

          "network" = {
            format-wifi = "  {essid}";
            format-ethernet = " Wired";
            tooltip-format = "{ifname} via {gwaddr}";
            format-linked = "{ifname} (No IP)";
            format-disconnected = "Disconnected";
            format-alt = "{ifname}: {ipaddr}/{cidr}";
          };

          "battery" = {
            states = {
              good = 95;
              warning = 30;
              critical = 15;
            };
            format = "{icon} {capacity}%";
            format-charging = " {capacity}%";
            format-plugged = " {capacity}%";
            format-alt = "{time} {icon}";
            format-icons = [
              ""
              ""
              ""
              ""
              ""
            ];
          };

          "tray" = {
            icon-size = 21;
            spacing = 10;
          };
        };
      };
    };
  };
}
