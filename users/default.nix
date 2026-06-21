{
  inputs,
  self,
  ...
}:
let

  mkHome =
    {
      system,
      modules,
      overlays ? [ ],
      # Standalone home builds have no system; supply a default hostFacts projection
      # (ADR-0018, slice 12) so home modules that read host state still resolve. These
      # are desktop configs, so gui is granted; nothing exposed/secret.
      hostFacts ? {
        exposed = false;
        platform = system;
        granted = {
          gui.enable = true;
          workstation.enable = false;
          virtualization.enable = false;
        };
      },
    }:
    inputs.home-manager.lib.homeManagerConfiguration {
      pkgs = import inputs.nixpkgs {
        inherit system;
        # The emacs overlay rides the gui grant (as in the contract gui feature module);
        # standalone builds its own pkgs, so add it here when gui is granted.
        overlays = [
          self.lib.overlays.default
        ]
        ++ overlays
        ++ inputs.nixpkgs.lib.optionals hostFacts.granted.gui.enable [
          inputs.emacs-overlay.overlays.default
        ];
        config = {
          allowUnfree = true;
          # A gui app pulls electron; the nixos path permits this in the user module,
          # so standalone (its own pkgs) must too when gui is granted.
          permittedInsecurePackages = inputs.nixpkgs.lib.optionals hostFacts.granted.gui.enable [
            "electron-39.8.10"
          ];
        };
      };
      extraSpecialArgs = { inherit inputs self hostFacts; };
      # Standalone builds have no nixos integration to set the home-profile enables
      # (which drive base.nix → home.username/homeDirectory/stateVersion). Mirror what
      # users/<u>/nixos/default.nix sets, derived from the same hostFacts (slice 12).
      modules = [
        (
          { lib, ... }:
          {
            # Only the contract-declared home profiles (cli, gui) — restic and others
            # are per-user options, not universal, so they can't be set generically.
            custom.home.profiles = {
              cli.enable = lib.mkDefault true;
              gui.enable = lib.mkDefault hostFacts.granted.gui.enable;
            };
          }
        )
      ]
      ++ modules;
    };

in
{
  flake.homeConfigurations = {
    "inkpotmonkey" = mkHome {
      system = "x86_64-linux";
      modules = [
        ./inkpotmonkey/home/default.nix
        self.homeManagerModules.options
        {
          identity = {
            name = "Inkpot Monkey";
            email = "inkpot-monkey@palebluebytes.space";
            username = "inkpotmonkey";
          };
          # nixpkgs config (allowUnfree, insecure permits) is governed by mkHome's
          # pkgs (slice 12) — setting it here would override that to empty.
        }
      ];
    };

    "general" = mkHome {
      system = "x86_64-linux";
      modules = [
        ./general/home/default.nix
        self.homeManagerModules.options
        {
          # general's home is a flat package list (no base.nix), so the home
          # essentials the nixos integration would supply are set here for standalone.
          home.username = "general";
          home.homeDirectory = "/home/general";
          home.stateVersion = "25.11";
        }
      ];
    };

    "eyeofalligator" = mkHome {
      system = "x86_64-linux";
      modules = [
        ./eyeofalligator/home/default.nix
        self.homeManagerModules.options
        {
          home.username = "eyeofalligator";
          home.homeDirectory = "/home/eyeofalligator";
          home.stateVersion = "25.11";
        }
      ];
    };
  };

  # =========================================
  # NixOS Modules (System)
  # =========================================
  flake.users = {
    inkpotmonkey = import ./inkpotmonkey/default.nix;

    general = import ./general/default.nix;

    eyeofalligator = import ./eyeofalligator/default.nix;
  };
}
