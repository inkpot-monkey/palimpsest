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
    {
      # 1. User shell
      users.users.eyeofalligator.shell = pkgs.bash;

      # 2. KDE Plasma 6 & X11
      services = {
        xserver = {
          enable = true;
          xkb = {
            layout = "gb";
            variant = "";
          };
        };
        displayManager.sddm.enable = lib.mkDefault true;
        desktopManager.plasma6.enable = true;
      };

      # 3. Flatpak
      services.flatpak.enable = true;

      # 4. Steam
      programs.steam.enable = true;

      # 5. Tailscale
      custom.profiles.tailscale.enable = true;

      # 6. Bluetooth
      custom.profiles.bluetooth.enable = true;

      # 7. Printing
      services.printing.enable = true;

      # 8. KDE Connect
      programs.kdeconnect.enable = true;

      # 9. Silent Auto-Updates
      system.autoUpgrade = {
        enable = true;
        allowReboot = false;
        flake = self.outPath;
        flags = [
          "--update-input"
          "nixpkgs"
          "--commit-lock-file"
        ];
        dates = "04:00";
      };

      # 6. Home Manager Configuration
      home-manager = {
        useUserPackages = true;
        useGlobalPkgs = true;
        extraSpecialArgs = {
          inherit inputs self;
        };
        users.eyeofalligator =
          { osConfig, ... }:
          let
            inherit (osConfig.custom.users.eyeofalligator) identity;
          in
          {
            imports = [
              ../home/default.nix
              self.homeManagerModules.options
            ];
            home.stateVersion = "24.05";
            inherit identity;
          };
      };
    }
  ];
}
