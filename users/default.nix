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
    }:
    inputs.home-manager.lib.homeManagerConfiguration {
      pkgs = import inputs.nixpkgs {
        inherit system;
        overlays = [ self.lib.overlays.default ] ++ overlays;
        config = {
          allowUnfree = true;
        };
      };
      extraSpecialArgs = { inherit inputs self; };
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
          nixpkgs.config.permittedInsecurePackages = [
            "beekeeper-studio-5.5.7"
          ];
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
  };

  # =========================================
  # NixOS Modules (System)
  # =========================================
  flake.users = {
    inkpotmonkey = import ./inkpotmonkey/default.nix;

    general = import ./general/default.nix;
  };
}
