{
  self,
  inputs,
  ...
}:
let
  inherit (self.lib) mkSystem mkPiSystem;
in
{
  flake.nixosConfigurations = {
    stargazer = mkSystem {
      system = "x86_64-linux";
      modules = [
        ./stargazer/configuration.nix
        self.users.inkpotmonkey.gui
      ];
    };

    weedySeadragon = mkSystem {
      system = "x86_64-linux";
      modules = [
        ./weedySeadragon/configuration.nix
        self.users.eyeofalligator
      ];
    };

    sawtoothShark = mkSystem {
      system = "x86_64-linux";
      modules = [
        ./sawtoothShark/configuration.nix
        self.users.inkpotmonkey.gui
        self.users.general.gui
      ];
    };

    # Note: To build the SD image for porcupineFish manually, run:
    # nix build '.#nixosConfigurations.porcupineFish.config.system.build.images.sd-card'
    # just deploy porcupineFish
    # nixos-rebuild --target-host porcupineFish --sudo --ask-sudo-password switch --flake .#porcupineFish
    porcupineFish = mkPiSystem {
      system = "aarch64-linux";
      specialArgs = {
        homeManagerInput = inputs.home-manager-25_11;
      };
      modules = [
        ./porcupineFish/configuration.nix
        self.users.inkpotmonkey.cli
        # Replace the stable blocky module with the unstable one to use modern options (e.g. denylists)
        {
          disabledModules = [ "services/networking/blocky.nix" ];
          imports = [ "${inputs.nixpkgs}/nixos/modules/services/networking/blocky.nix" ];
        }
      ];
    };

    # just deploy kelpy
    # nixos-rebuild --target-host kelpy --sudo --ask-sudo-password switch --flake .#kelpy
    kelpy = mkSystem {
      system = "x86_64-linux";
      modules = [
        ./kelpy/configuration.nix
        self.users.inkpotmonkey.cli
      ];
    };

    potbelliedSeahorse = mkSystem {
      system = "x86_64-linux";
      modules = [
        ./potbelliedSeahorse/configuration.nix
        self.users.inkpotmonkey.cli
      ];

    };
  };
}
