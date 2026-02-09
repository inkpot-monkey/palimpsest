{
  pkgs,
  inputs,
  ...
}:
{
  # =========================================
  # Imports
  # =========================================
  imports = [
    inputs.sops-nix.homeManagerModule
  ];

  # =========================================
  # Home Manager Settings
  # =========================================
  home = {
    username = "inkpotmonkey";
    homeDirectory = "/home/inkpotmonkey";
    stateVersion = "25.05";

    sessionVariables = {
      EMAIL = "inkpotmonkey@palebluebytes.space";
      SOPS_AGE_KEY_FILE = "/run/user/1001/secrets.d/age-keys.txt";
      # Spell Check
      DICPATH = "$HOME/.nix-profile/share/hunspell";
    };

    # =========================================
    # User Packages
    # =========================================
    packages = with pkgs; [
      # Spell Check
      # hunspell
      # enchant
      # hunspellDicts.en_GB-large
      # hunspellDicts.es_ES
    ];
  };

  # =========================================
  # Secrets Management (SOPS)
  # =========================================
  sops = {
    defaultSopsFile = ./secrets.yaml;
    age.sshKeyPaths = [ "/home/inkpotmonkey/.ssh/id_ed25519" ];
    secrets = {
      "github_token" = { };
      "apikey@search.brave.com" = { };
    };
  };

  # =========================================
  # XDG & Application Defaults
  # =========================================
  # XDG settings moved to gui.nix

  # =========================================
  # Systemd Services
  # =========================================
  systemd.user.startServices = "sd-switch";
}
