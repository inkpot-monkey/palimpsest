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
  ];

  config = lib.mkMerge [
    # =========================================
    # Base User Configuration (runs on CLI & GUI)
    # =========================================
    {
      # 1. User shell (Account creation handled by User Manager)
      users.users.inkpotmonkey.shell = pkgs.bash;

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
          let
            inherit (osConfig.custom.users.inkpotmonkey) identity;
          in
          {
            imports = [
              ../home/default.nix
              self.homeManagerModules.options
            ];

            # Explicitly pass the system identity to Home Manager user
            inherit identity;

            # =========================================
            # Enable Home Manager Profiles
            # =========================================
            custom.home.profiles = {
              cli.enable = true;
              gui.enable = osConfig.custom.users.inkpotmonkey.identity.profile == "gui";
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
    (lib.mkIf (config.custom.users.inkpotmonkey.identity.profile == "gui") {
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
