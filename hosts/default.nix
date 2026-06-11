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
          # Coder MoE (~3.3B active params), so it's bandwidth-cheap and fast on the RK3588 —
          # unlike a dense 27B, which reads all weights per token and is bandwidth-bound at
          # <1 tok/s. MTP/draft speculative decoding gave no CPU benefit (benchmarked 0.80 vs
          # 0.84 tok/s), so it stays off.
          # TEMP: UD-Q3_K_XL (13.8G) to fit the 29G eMMC; bump to Q5_K_XL once the NVMe is in.
          custom.rk1.llm.model = "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:UD-Q3_K_XL";
          # 64K context (native 256K). This coder's KV is larger (~0.09 MB/tok), so 64K uses
          # ~22G RAM with ~9.5G free (safe for prefill buffers); 128K would leave only ~3.4G.
          # For more, switch to q8_0 KV (flashAttention = true) to ~halve KV at ~3% decode cost.
          custom.rk1.llm.ctxSize = 65536;
        }
      ];
    };
  };
}
