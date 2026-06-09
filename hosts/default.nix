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

    weedySeadragon = mkSystem {

      modules = [
        ./weedySeadragon/configuration.nix
        self.users.inkpotmonkey.gui
        self.users.eyeofalligator
      ];
    };

    sawtoothShark = mkSystem {

      modules = [
        ./sawtoothShark/configuration.nix
        self.users.inkpotmonkey.gui
        # self.users.general.gui
      ];
    };

    # Note: To build the SD image for porcupineFish manually, run:
    # nix build '.#nixosConfigurations.porcupineFish.config.system.build.images.sd-card'
    # just deploy porcupineFish
    # nixos-rebuild --target-host porcupineFish --sudo --ask-sudo-password switch --flake .#porcupineFish
    porcupineFish = mkPiSystem {

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
    #
    # Initial build on a fresh VPS (before inkpotmonkey user exists):
    # nixos-rebuild --target-host root@<ip> switch --flake .#kelpy
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

    # Turing Pi RK1 nodes (RK3588, 32 GB). Shared config in ./rk1/common.nix;
    # each node differs only by hostname + served model.
    #
    # Deploy (build on the node itself — aarch64):
    # nixos-rebuild switch --flake .#rk1a \
    #   --target-host nixos@<ip> --build-host nixos@<ip> --use-remote-sudo
    rk1a = mkSystem {
      modules = [
        ./rk1/common.nix
        self.users.inkpotmonkey.cli
        {
          networking.hostName = "rk1a";
          # Fast MoE daily driver (3B active → ~10-15 tok/s on CPU).
          custom.profiles.localLlm.model = "unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_XL";
        }
      ];
    };

    rk1b = mkSystem {
      modules = [
        ./rk1/common.nix
        self.users.inkpotmonkey.cli
        {
          networking.hostName = "rk1b";
          # Best-quality dense coder + speculative decoding (~3-4 tok/s).
          custom.profiles.localLlm = {
            model = "unsloth/Qwen3.6-27B-GGUF:Q4_K_M";
            draftModel = "unsloth/Qwen3.6-1.7B-GGUF:Q4_K_M";
          };
        }
      ];
    };
  };
}
