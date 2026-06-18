{
  pkgs,
  lib,
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

      # 2. GUI: the shared display infrastructure (sddm + plasma6 + Wayland) comes
      # from the gui grant via contract/realization.nix (see default.nix). A host
      # that wants an X11 session enables services.xserver itself (weedySeadragon
      # does). This is what lets eyeofalligator share a host with inkpotmonkey
      # instead of fighting over services.xserver.enable.

      # 3. Flatpak & Discover Support
      services.flatpak.enable = true;
      environment.systemPackages = [
        pkgs.kdePackages.discover
        pkgs.kdePackages.flatpak-kcm
      ];

      # 4. Steam
      programs.steam.enable = true;

      # 5. Tailscale
      custom.profiles.tailscale.enable = true;

      # 6. Bluetooth
      custom.profiles.bluetooth.enable = true;

      # 7. Printing & Scanning
      services.printing.enable = true;
      hardware.sane.enable = true;

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

      # 10. Compatibility
      programs.nix-ld.enable = true;

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
