{
  pkgs,
  inputs,
  self,
  ...
}:
{
  imports = [
    inputs.sops-nix.homeManagerModule
    ./goose.nix
    # ./emacs - if it exists, I'll need to check the path
  ];

  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  sops.defaultSopsFile = self.lib.getSecretPath "shared.yaml";

  home.packages = with pkgs; [
    kdePackages.kate
    slack
    mpv
    protonvpn-gui
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
