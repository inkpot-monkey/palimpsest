{
  pkgs,
  ...
}:
{
  imports = [
    # ./emacs - if it exists, I'll need to check the path
  ];

  home.packages = with pkgs; [
    kdePackages.kate
    slack
    mpv
    pkgs."proton-vpn"
    qbittorrent
    anki
    nodejs
    python3
  ];

  # Mime types from original plasma.nix
  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "text/html" = "vivaldi-stable.desktop";
      "x-scheme-handler/http" = "vivaldi-stable.desktop";
      "x-scheme-handler/https" = "vivaldi-stable.desktop";
      "x-scheme-handler/about" = "vivaldi-stable.desktop";
      "x-scheme-handler/unknown" = "vivaldi-stable.desktop";
    };
  };
}
