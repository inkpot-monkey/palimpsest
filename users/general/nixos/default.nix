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
      nixpkgs.overlays = [ inputs.emacs-overlay.overlays.default ];

      # 1. User shell (Account creation handled by User Manager)
      users.users.general.shell = pkgs.bash;

      # 2. Services (Plasma Desktop Environment)
      services = {
        # Enable the X11 windowing system
        xserver = {
          enable = true;
          # Configure keymap in X11
          xkb = {
            layout = "gb";
            variant = "";
          };
        };

        # Enable the KDE Plasma Desktop Environment
        displayManager.sddm.enable = true;
        desktopManager.plasma6.enable = true;
      };

      # Disable KDE Plasma Session Restoration
      environment.etc."xdg/ksmserverrc".text = ''
        [General]
        loginMode=emptySession
      '';

      # 3. Home Manager Configuration
      home-manager = {
        useUserPackages = true;
        useGlobalPkgs = true;
        extraSpecialArgs = {
          inherit
            inputs
            self
            ;
        };
        users.general =
          { osConfig, ... }:
          let
            inherit (osConfig.custom.users.general) identity;
          in
          {
            imports = [
              ../home/default.nix
              self.homeManagerModules.options
            ];
            home.stateVersion = "24.05";

            # Explicitly pass the system identity to Home Manager user
            inherit identity;
          };
      };

      # 4. Persistence
      environment.persistence."/persist" = lib.mkIf config.custom.profiles.impermanence.enable {
        # System-wide persistence migrated from general/default.nix (non-duplicates)
        directories = [
          "/var/lib/systemd/coredump"
          "/var/lib/bluetooth"
          "/etc/NetworkManager/system-connections"
        ];

        # User-specific persistence
        users.general = {
          directories = [
            "Downloads"
            "Music"
            "Pictures"
            "Documents"
            "Videos"
            "code"
            ".gemini"
            ".antigravity"
            ".config/Antigravity"
            ".config/beekeeper-studio"
            ".config/Slack"
            ".config/sops"
            ".ssh"
            ".config/vivaldi"
            ".local/share/direnv"
            ".config/goose"
            ".local/share/goose"
            ".local/share/cass"
            ".agent"
            ".claude"
            ".screenrc"
          ];
          files = [ ];
        };
      };
    }
  ];
}
