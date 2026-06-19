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
          restic.enable = false;
          workstation.enable = false;
          virtualization.enable = false;
        };
      },
    }:
    inputs.home-manager.lib.homeManagerConfiguration {
      pkgs = import inputs.nixpkgs {
        inherit system;
        overlays = [ self.lib.overlays.default ] ++ overlays;
        config = {
          allowUnfree = true;
        };
      };
      extraSpecialArgs = { inherit inputs self hostFacts; };
      inherit modules;
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
            profile = "gui";
            name = "Inkpot Monkey";
            email = "inkpot-monkey@palebluebytes.space";
            username = "inkpotmonkey";
          };
          nixpkgs.config.allowUnfree = true;
          nixpkgs.config.permittedInsecurePackages = [ ];
        }
      ];
    };

    "general" = mkHome {
      system = "x86_64-linux";
      modules = [
        ./general/home/default.nix
        self.homeManagerModules.options
        { identity.profile = "gui"; }
      ];
    };

    "eyeofalligator" = mkHome {
      system = "x86_64-linux";
      modules = [
        ./eyeofalligator/home/default.nix
        self.homeManagerModules.options
        { identity.profile = "gui"; }
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
