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
      overlays = [ inputs.emacs-overlay.overlays.default ];
      modules = [ ./inkpotmonkey/home/default.nix ];
    };

    "general" = mkHome {
      system = "x86_64-linux";
      modules = [
        ./general/home/default.nix
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
