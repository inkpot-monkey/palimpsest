{
  inputs,
  lib,
  self,
  ...
}:
let
  inherit (lib) mkSystem keys;
in
{
  stargazer = mkSystem {
    modules = [
      ./stargazer/configuration.nix
      inputs.disko.nixosModules.disko
      inputs.nixos-hardware.nixosModules.framework-13-7040-amd
    ];
  };

  # Note: To build the SD image for porcupineFish manually, run:
  # nix build .#nixosConfigurations.porcupineFish.config.system.build.sdImage
  porcupineFish = inputs.nixos-raspberrypi.lib.nixosSystem {
    modules = [
      ./porcupineFish/configuration.nix
    ];
    specialArgs = {
      inherit
        inputs
        self
        keys
        ;
      inherit (inputs) nixos-raspberrypi;
    };
  };

  kelpy = mkSystem {
    specialArgs = {
      settings = {
        admin = {
          email = "thomas@palebluebytes.xyz";
        };
        host = {
          ip4 = "37.205.14.206";
          ip6 = "2a03:3b40:fe:896::1";
          hostName = "kelpy";
          domain = "palebluebytes.space";
        };
      };
    };
    modules = [
      ./kelpy/configuration.nix
    ];
  };

  potbelliedSeahorse = mkSystem {
    system = "aarch64-linux";
    modules = [
      ./potbelliedSeahorse/configuration.nix
    ];
  };
}
