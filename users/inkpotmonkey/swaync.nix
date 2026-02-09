_:

{
  # =========================================
  # SwayNC Notification Daemon
  # =========================================
  services.swaync = {
    enable = true;

    # =========================================
    # Daemon Settings
    # =========================================
    settings = {
      positionX = "right";
      positionY = "top";
      layer = "overlay";
      control-center-layer = "top";
      layer-shell = true;
      cssPriority = "application";
      control-center-margin-top = 10;
      control-center-margin-bottom = 10;
      control-center-margin-right = 10;
      control-center-margin-left = 10;
      notification-2fa-action = true;
      notification-inline-replies = false;
      notification-window-width = 500;
      keyboard-shortcuts = true;
      image-visibility = "when-available";
      transition-time = 200;
      hide-on-clear = false;
      hide-on-action = true;
      script-fail-notify = true;
      widgets = [
        "title"
        "dnd"
        "notifications"
      ];
      widget-config = {
        title = {
          text = "Notifications";
          clear-all-button = true;
          button-text = "Clear All";
        };
        dnd = {
          text = "Do Not Disturb";
        };
        label = {
          max-lines = 5;
          text = "Label Text";
        };
        mpris = {
          image-size = 96;
          image-radius = 12;
        };
      };
    };

    # =========================================
    # Visual Styling (CSS)
    # =========================================
    style = ''
      /* Catppuccin Mocha Theme for SwayNC */
      * {
        font-family: "JetBrainsMono Nerd Font";
      }

      .control-center .notification-row:focus,
      .control-center .notification-row:hover {
        opacity: 1;
        background: #1e1e2e;
      }

      .notification-row {
        outline: none;
        margin-bottom: 5px;
        margin-top: 5px;
        background: #181825;
        padding: 0;
        border-radius: 12px;
      }

      .notification {
        background: transparent;
        padding: 0;
        margin: 0px;
      }

      .notification-content {
        background: #1e1e2e;
        padding: 0px;
        border-radius: 12px;
        border: none;
      }

      .notification-default-action {
        margin: 0;
        padding: 0;
        border-radius: 12px;
      }

      .close-button {
        background: #f38ba8;
        color: #1e1e2e;
        text-shadow: none;
        padding: 0;
        border-radius: 12px;
        margin-top: 5px;
        margin-right: 5px;
      }

      .close-button:hover {
        box-shadow: none;
        background: #d20f39;
        transition: all .2s ease-in-out;
      }

      .notification-action {
        border: 2px solid #313244;
        border-top: none;
        border-radius: 12px;
      }

      .widget-title {
        color: #cdd6f4;
        background: #1e1e2e;
        padding: 10px 20px;
        margin: 10px 10px 5px 10px;
        font-size: 1.5rem;
        border-radius: 12px;
        border: 1px solid #313244;
      }

      .widget-title > button {
        font-size: 1rem;
        color: #cdd6f4;
        text-shadow: none;
        background: #313244;
        box-shadow: none;
        border-radius: 12px;
        border: none;
        padding: 5px 10px;
      }

      .widget-title > button:hover {
        background: #45475a;
      }

      .widget-dnd {
        background: #1e1e2e;
        padding: 10px 20px;
        margin: 5px 10px 10px 10px;
        border-radius: 12px;
        font-size: 1.1rem;
        color: #cdd6f4;
        border: 1px solid #313244;
      }

      .widget-dnd > switch {
        border-radius: 12px;
        background: #313244;
      }

      .widget-dnd > switch:checked {
        background: #89b4fa;
        border: 1px solid #89b4fa;
      }

      .widget-dnd > switch slider {
        background: #cdd6f4;
        border-radius: 12px;
      }

      .widget-label {
        margin: 10px 10px 5px 10px;
      }

      .widget-label > label {
        font-size: 1.1rem;
        color: #cdd6f4;
      }

      .widget-mpris {
        color: #cdd6f4;
        background: #1e1e2e;
        padding: 10px;
        margin: 10px;
        border-radius: 12px;
        border: 1px solid #313244;
      }

      .widget-mpris > box > button {
        border-radius: 12px;
      }

      .widget-mpris-player {
        padding: 5px 10px;
        margin: 10px;
      }

      .widget-mpris-title {
        font-weight: 700;
        font-size: 1.25rem;
      }

      .widget-mpris-subtitle {
        font-size: 1.1rem;
      }
    '';
  };
}
