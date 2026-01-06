# This is your home-manager and os user configuration file
{
  settings = {
    username = "inkpotmonkey";
    email = "inkpot@palebluebytes.space";
    hashedPassword = "<SCRUBBED_PASSWORD>";
    sshPubKey = "<SCRUBBED_SSH_KEY>";

    # =========================================
    # User Permissions & Groups
    # =========================================
    extraGroups = [
      "input"
      "uinput"
      "podman"
      "docker"
      "plugdev"
      "disk"
      "qemu-libvirtd"
      "dialout"
      "libvirt"
      "networkmanager"
      "audio"
      "video"
      "wheel"
    ];
  };

  config =
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

        ./cli.nix
        ./gui.nix
        ./emacs
        ./hyprland.nix
        ./waybar.nix
        ./swaync.nix

        # ./finance
        # ./git-annex.nix
      ];

      # =========================================
      # Home Manager Settings
      # =========================================
      home.stateVersion = "25.05";
      home.sessionVariables = {
        EMAIL = "inkpotmonkey@palebluebytes.space";
        SOPS_AGE_KEY_FILE = "/run/user/1001/secrets.d/age-keys.txt";
        # Spell Check
        DICPATH = "$HOME/.nix-profile/share/hunspell";
      };

      # =========================================
      # User Packages
      # =========================================
      home.packages = with pkgs; [
        # Fonts
        recursive
        montserrat
        libre-caslon

        # System Utilities
        brightnessctl
        playerctl
        grim
        slurp
        swayosd # OSD for volume/brightness

        # Spell Check
        hunspell
        enchant
        hunspellDicts.en_GB-large
        hunspellDicts.es_ES
      ];

      # =========================================
      # Secrets Management (SOPS)
      # =========================================
      sops = {
        defaultSopsFile = ./secrets.yaml;
        age.sshKeyPaths = [ "/home/inkpotmonkey/.ssh/id_ed25519" ];
        secrets = {
          "github_token" = { };
        };
      };

      # =========================================
      # XDG & Application Defaults
      # =========================================
      xdg = {
        enable = true;
        mimeApps = {
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

      # =========================================
      # Systemd Services
      # =========================================
      systemd.user.startServices = "sd-switch";
    };
}
