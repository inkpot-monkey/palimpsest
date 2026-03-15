{
  pkgs,
  lib,
  config,
  inputs,
  self,
  homeManagerInput,
  ...
}:

{
  imports = [
    homeManagerInput.nixosModules.home-manager
    ../identity.nix
  ];

  config = lib.mkMerge [
    # =========================================
    # Base User Configuration (runs on CLI & GUI)
    # =========================================
    {
      users.users.inkpotmonkey = {
        isNormalUser = true;
        hashedPassword = "<SCRUBBED_PASSWORD>";
        extraGroups = [
          "podman"
          "docker"
          "networkmanager"
          "audio"
          "video"
          "wheel"
        ];
        shell = pkgs.bash;
        openssh.authorizedKeys.keys = [
          config.identity.sshKey
        ];
      };

      # =========================================
      # Home Manager Configuration
      # =========================================
      home-manager = {
        useUserPackages = true;
        useGlobalPkgs = true;
        extraSpecialArgs = {
          inherit
            inputs
            self
            ;
        };
        backupFileExtension = "backup";
        users.inkpotmonkey =
          { osConfig, ... }:
          {
            imports = [
              ../home/default.nix
            ];
            # Explicitly pass the system identity to Home Manager user
            config.identity = osConfig.identity;

            # =========================================
            # Enable Home Manager Profiles
            # =========================================
            config.custom.home.profiles = {
              base.enable = true;
              shell.enable = true;
              git.enable = true;
              ssh.enable = true;
              dev.enable = true;
              goose.enable = true;

              # GUI Specific Profiles
              ai.enable = osConfig.identity.profile == "gui";
              gui.enable = osConfig.identity.profile == "gui";
              hyprland.enable = osConfig.identity.profile == "gui";
              waybar.enable = osConfig.identity.profile == "gui";
              swaync.enable = osConfig.identity.profile == "gui";
              hyprlock.enable = osConfig.identity.profile == "gui";
              email.enable = osConfig.identity.profile == "gui";
              emacs.enable = osConfig.identity.profile == "gui";
              restic.enable = osConfig.identity.profile == "gui";
              git-annex.enable = osConfig.identity.profile == "gui";
            };
          };
      };

      # Fix for XDG Desktop Portal with home-manager.useUserPackages
      environment.pathsToLink = [
        "/share/xdg-desktop-portal"
        "/share/applications"
      ];
    }

    # =========================================
    # GUI Configuration (Guarded by Profile)
    # =========================================
    (lib.mkIf (config.identity.profile == "gui") {
      hardware.uinput.enable = true;
      services.kanata = {
        enable = true;
        keyboards.default = {
          configFile = ../home/configs/kanata.kbd;
          extraDefCfg = "process-unmapped-keys yes";
        };
      };

      programs.hyprland.enable = true;

      users.users.inkpotmonkey = {
        extraGroups = [
          "input"
          "uinput"
          # For zsa keyboard
          "plugdev"
          "disk"
          "qemu-libvirtd"
          "dialout"
          "libvirtd"
        ];
      };

      nixpkgs.config.permittedInsecurePackages = [
        "beekeeper-studio-5.5.7"
      ];
    })
  ];
}
