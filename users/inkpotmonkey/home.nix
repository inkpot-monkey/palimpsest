# This is your home-manager and os user configuration file
{
  settings = {
    username = "inkpotmonkey";
    email = "inkpot@palebluebytes.space";
    hashedPassword = "<SCRUBBED_PASSWORD>";
    sshPubKey = "<SCRUBBED_SSH_KEY>";
    # A list of groups the user wants to belong to
    # The final groups the user actually belongs to will depend on what the system allows
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
      imports = [
        inputs.sops-nix.homeManagerModule

        ./cli.nix
        ./gui.nix
        ./emacs
      ];

      sops = {
        defaultSopsFile = ./secrets.yaml;
        age.sshKeyPaths = [ "/home/inkpotmonkey/.ssh/id_ed25519" ];
        secrets = {
          "github_token" = { };
        };
      };

      xdg = {
        enable = true;
        mimeApps = {
          enable = pkgs.stdenv.isLinux;
          defaultApplications = {
            "text/html" = [ "vivaldi.desktop" ];
            "x-scheme-handler/mailto" = [ "vivaldi.desktop" ];
            "x-scheme-handler/http" = [ "vivaldi.desktop" ];
            "x-scheme-handler/https" = [ "vivaldi.desktop" ];
            "x-scheme-handler/about" = [ "vivaldi.desktop" ];
            "x-scheme-handler/unknown" = [ "vivaldi.desktop" ];
          };
        };
      };

      # Nicely reload system units when changing configs
      systemd.user.startServices = "sd-switch";

      # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
      home.stateVersion = "25.05";

      home.packages = with pkgs; [ recursive ];

      home.sessionVariables = {
        EMAIL = "inkpotmonkey@palebluebytes.space";
      };
    };
}
