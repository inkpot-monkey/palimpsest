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
      modules = [
        ./stargazer/configuration.nix
        self.users.inkpotmonkey.gui
      ];
    };

    sawtoothShark = mkSystem {
      modules = [
        ./sawtoothShark/configuration.nix
        self.users.general
      ];
    };

    # Note: To build the SD image for porcupineFish manually, run:
    # nix build '.#nixosConfigurations.porcupineFish.config.system.build.images.sd-card'
    # nixos-rebuild --target-host inkpotmonkey@porcupineFish --sudo --ask-sudo-password switch --flake .#porcupineFish
    porcupineFish = mkPiSystem {
      specialArgs = {
        homeManagerInput = inputs.home-manager-25_11;
      };
      modules = [
        ./porcupineFish/configuration.nix
        self.users.inkpotmonkey.cli
      ];
    };

    # nixos-rebuild --target-host inkpotmonkey@kelpy --sudo --ask-sudo-password switch --flake .#kelpy
    # 37.205.14.206
    kelpy = mkSystem {
      modules = [
        ./kelpy/configuration.nix
        self.users.inkpotmonkey.cli
      ];
    };

    potbelliedSeahorse = mkSystem {
      modules = [
        ./potbelliedSeahorse/configuration.nix
        self.users.inkpotmonkey.cli
      ];

    };
  };
}
