{
  self,
  inputs,
  ...
}:
let
  inherit (self.lib) mkSystem mkPiSystem;
  # Grant-as-data (ADR-0018, slice 16): a host grants a user's features here, as data,
  # next to where it binds the user — never by importing a self-granting variant. This
  # is the fleet's grant matrix; `granted.*` is host-write-only, the user never sets it.
  grant = user: features: { custom.users.${user}.granted = features; };
in
{
  flake.nixosConfigurations = {
    stargazer = mkSystem {

      modules = [
        ./stargazer/configuration.nix
        self.users.inkpotmonkey.manifest
        (grant "inkpotmonkey" {
          gui.enable = true;
          workstation.enable = true;
          virtualization.enable = true;
          signing.enable = true;
        })
      ];
    };

    weedySeadragon = mkSystem {

      modules = [
        ./weedySeadragon/configuration.nix
        self.users.inkpotmonkey.manifest
        self.users.eyeofalligator
        (grant "inkpotmonkey" {
          gui.enable = true;
          workstation.enable = true;
          virtualization.enable = true;
        })
        # eyeofalligator co-administers this laptop and had sudo pre-clamp (its identity
        # declares wheel); the clamp drops untrusted identity groups, so its sudo must be
        # an explicit grant now (ADR-0015 threat model; cloud-review finding).
        (grant "eyeofalligator" {
          gui.enable = true;
          sudo.enable = true;
        })
        # The break-glass admin account (declared in ./weedySeadragon/configuration.nix)
        # is a contract user too, so its wheel is also clamped unless granted. Grant sudo
        # so the recovery account keeps root if the primary login breaks.
        (grant "admin" { sudo.enable = true; })
      ];
    };

    sawtoothShark = mkSystem {

      modules = [
        ./sawtoothShark/configuration.nix
        self.users.inkpotmonkey.manifest
        (grant "inkpotmonkey" {
          gui.enable = true;
          workstation.enable = true;
          virtualization.enable = true;
          signing.enable = true;
        })
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
        self.users.inkpotmonkey.manifest
        (grant "inkpotmonkey" { workstation.enable = true; })
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
        self.users.inkpotmonkey.manifest
        # kelpy is exposed: it gets workstation (docker/podman/wheel) but no
        # secret-bearing feature. Now that the grant is explicit here, dropping it is a
        # one-line change (see the exposed-host note in contract/realization.nix).
        (grant "inkpotmonkey" { workstation.enable = true; })
      ];
    };

    potbelliedSeahorse = mkSystem {

      modules = [
        ./potbelliedSeahorse/configuration.nix
        self.users.inkpotmonkey.manifest
        (grant "inkpotmonkey" { workstation.enable = true; })
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
        self.users.inkpotmonkey.manifest
        (grant "inkpotmonkey" { workstation.enable = true; })
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
        self.users.inkpotmonkey.manifest
        (grant "inkpotmonkey" { workstation.enable = true; })
        {
          networking.hostName = "rk1b";
          # rk1b is the voice node, NOT an LLM server. The qwen-coder MoE was removed to free
          # ~22G RAM + 13G eMMC for Home Assistant. custom.rk1.llm is therefore left disabled
          # (default). The coder model still exists in the cloud as `qwen3-coder` (DeepInfra) via
          # kelpy's LiteLLM; rk1a serves the local general MoE (qwen-general).
          #
          # Home Assistant + local Wyoming voice (STT/TTS); the wake word runs on the phone.
          # See modules/nixos/profiles/homeassistant.nix. The real-time STT here is the small
          # base-int8 faster-whisper; voice latency isn't critical so it's fine on CPU.
          # (Heavyweight WhisperX batch transcription lives on stargazer now — its Zen 5 CPU is
          # ~8-10x faster than the A76s for large-v3, so an hour of audio takes ~15 min vs ~2h.)
          custom.profiles.homeassistant.enable = true;

          # NVMe (Samsung PM981, 512G, fitted Jun 2026): /nix on the `nixstore` partition (128G)
          # so the store has room for build offload (this node is the fleet's aarch64 remote
          # builder — see modules/nixos/profiles/pi-builder.nix), keeping the 29G eMMC from
          # overflowing. The `rk1cache` partition (349G) mounts at /var/cache for telemetry,
          # paperless, and other data services (repartitioned Jun 2026; was 400G nixstore +
          # 77G rk1cache — inverted since the store only needs ~10G and data needs the room).
          custom.rk1.nvme.enable = true;
          custom.rk1.nvme.relocateNixStore = true;

          # Off-host uptime watcher (Gatus): rk1b is always-on and not kelpy, so it
          # can observe kelpy failing. Probes the fleet + alerts to #infra-alerts.
          # See ADR-0026 / modules/nixos/profiles/monitoring/watcher.nix.
          custom.profiles.monitoring-watcher.enable = true;
          # Out-of-band web-push alerter (ADR-0027): fires the phone when the Matrix
          # delivery path itself is down. topic + publish_token from monitoring.yaml.
          custom.profiles.monitoring-watcher.outOfBand.enable = true;
        }
      ];
    };
  };
}
