{
  inputs,
  lib,
  self,
  ...
}:
let
  inherit (lib) mkPkgs keys;

  mkHome =
    {
      system,
      modules,
    }:
    inputs.home-manager.lib.homeManagerConfiguration {
      pkgs = mkPkgs system;
      extraSpecialArgs = { inherit inputs self keys; };
      inherit modules;
    };

  commonModules = [
    ./inkpotmonkey/cli.nix
    ./inkpotmonkey/default.nix # Contains core settings
  ];

  desktopModules = [
    ./inkpotmonkey/email.nix
    ./inkpotmonkey/emacs
    ./inkpotmonkey/gui.nix
    ./inkpotmonkey/hyprland.nix
  ];
in
{
  "inkpotmonkey" = mkHome {
    system = "x86_64-linux";
    modules = commonModules ++ desktopModules;
  };

  "inkpotmonkey-headless" = mkHome {
    system = "aarch64-linux";
    modules = commonModules;
  };
}
