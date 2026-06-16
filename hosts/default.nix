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
          custom.rk1.llm.enable = true;
          # Fast MoE daily driver (3B active → ~10-15 tok/s on CPU).
          # TEMP: Q3_K_S (15.4G) to fit the 29G eMMC; restore UD-Q4_K_XL (22.4G) once the NVMe is in.
          custom.rk1.llm.model = "unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q3_K_S";
          # 128K context (native 256K). This MoE's KV is tiny (~0.02 MB/tok) so 128K uses only
          # ~20G RAM total, ~12G free — measured. KV is allocated upfront; decode speed only
          # drops as the window actually fills.
          custom.rk1.llm.ctxSize = 131072;
        }
      ];
    };

    rk1b = mkSystem {
      modules = [
        ./rk1/common.nix
        self.users.inkpotmonkey.cli
        {
          networking.hostName = "rk1b";
          # rk1b is the voice node, NOT an LLM server. The qwen-coder MoE was removed to free
          # ~22G RAM + 13G eMMC for Home Assistant (and, later, WhisperX once the NVMe is in).
          # custom.rk1.llm is therefore left disabled (default). The coder model still exists
          # in the cloud as `qwen3-coder` (DeepInfra) via kelpy's LiteLLM; rk1a continues to
          # serve the local general MoE (qwen-general).
          #
          # Home Assistant + local Wyoming voice (STT/TTS); the wake word runs on the phone.
          # Small footprint (no torch). See hosts/rk1/homeassistant.nix.
          custom.rk1.homeAssistant.enable = true;
        }
      ];
    };
  };
}
