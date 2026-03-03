{
  # Services
  services = {
    # Enable the X11 windowing system
    xserver = {
      enable = true;
      # Configure keymap in X11
      xkb = {
        layout = "gb";
        variant = "";
      };
    };

    # Enable the KDE Plasma Desktop Environment
    displayManager.sddm.enable = true;
    desktopManager.plasma6.enable = true;
  };

  # Disable KDE Plasma Session Restoration
  environment.etc."xdg/ksmserverrc".text = ''
    [General]
    loginMode=emptySession
  '';

  # Set Default Browser
  xdg.mime.defaultApplications = {
    "text/html" = "vivaldi-stable.desktop";
    "x-scheme-handler/http" = "vivaldi-stable.desktop";
    "x-scheme-handler/https" = "vivaldi-stable.desktop";
    "x-scheme-handler/about" = "vivaldi-stable.desktop";
    "x-scheme-handler/unknown" = "vivaldi-stable.desktop";
  };
}
