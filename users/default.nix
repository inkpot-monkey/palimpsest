{
  inputs,
  self,
  ...
}:
let
  inherit (self.lib) mkPkgs;

  mkHome =
    {
      system,
      modules,
    }:
    inputs.home-manager.lib.homeManagerConfiguration {
      pkgs = mkPkgs system;
      extraSpecialArgs = { inherit inputs self; };
      inherit modules;
    };

in
{
  flake.homeConfigurations = {
    "inkpotmonkey" = mkHome {
      system = "x86_64-linux";
      modules = [ ./inkpotmonkey/home/default.nix ];
    };

    "general" = mkHome {
      system = "x86_64-linux";
      modules = [
        ./general/default.nix
      ];
    };
  };

  # =========================================
  # NixOS Modules (System)
  # =========================================
  flake.users = {
    inkpotmonkey = import ./inkpotmonkey/default.nix;

    general = ./general/default.nix;
  };
}
