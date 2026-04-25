{
  pkgs,
  inputs,
  self, ...
}:
{
  imports = [
    inputs.sops-nix.homeManagerModule
  ];

  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  sops.defaultSopsFile = self.lib.getSecretPath "shared.yaml";

  home.packages = with pkgs; [
    kdePackages.kate
    google-chrome
    firefox
    spotify
    libreoffice-qt
    mpv
  ];

  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "text/plain" = "kate.desktop";
    };
  };
}
