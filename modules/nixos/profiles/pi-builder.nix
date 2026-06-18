# Use the Turing Pi RK1 nodes (rk1a/rk1b, RK3588, native aarch64) as remote build
# machines for the build host, so Pi sd-images build natively instead of under slow
# QEMU emulation.
#
# GATED OFF by default. The rk1 nodes boot from a 29 GB eMMC with no room to assemble a
# ~6.8 GB Pi sd-image (a native build there fails with "No space left on device"). A node
# is only a usable builder once it has an NVMe-backed /nix/store — see hosts/rk1/nvme.nix
# (`custom.rk1.nvme.relocateNixStore`). Use `enabledNodes` to list only the nodes that have
# it: currently just rk1b (rk1a has no drive). Enable checklist:
#   1. Fit an NVMe in the node; set custom.rk1.nvme.enable + relocateNixStore; migrate /nix.
#   2. Confirm `df /nix` on the node shows the NVMe with headroom.
#   3. On the build host (sawtoothShark): custom.profiles.piBuilder.enable = true and set
#      enabledNodes to the NVMe-equipped nodes.
#   4. Smoke-test: `nix build .#nixosConfigurations.porcupineFish.config.system.build.sdImage`
#      and confirm it offloads to rk1 (no local QEMU kernel/initrd build).
#
# Auth model: nix-daemon (root) on the build host SSHes to the rk1 nodes as `inkpotmonkey`,
# which is already a trusted nix user there (`@wheel` in profiles/nixConfig.nix) and whose
# key is authorised via secrets/identities.nix. No dedicated build user/key needed.
{
  config,
  lib,
  ...
}:

let
  cfg = config.custom.profiles.piBuilder;

  # `nix.buildMachines.*.publicHostKey` wants base64(`/etc/ssh/ssh_host_ed25519_key.pub`).
  # Regenerate with: ssh-keyscan -t ed25519 rk1a | sed 's/^rk1a //' | base64 -w0
  nodes = [
    {
      hostName = "rk1a"; # tailnet MagicDNS name (NOT "turing-rk1")
      publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUY2SnpQQUFUYWRPbUJHa3pjakZFZXlEZlNHUFhNbjdjMmEyVDc0OG9Tdlg=";
    }
    {
      hostName = "rk1b";
      publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSU04dmNXSmxmVkF4MHAzODRPWm5pVXV1bzY2b1luQzlYbFBhZWFqTVp0VE0=";
    }
  ];
in
{
  options.custom.profiles.piBuilder = {
    enable = lib.mkEnableOption ''
      offloading aarch64 builds to the Turing Pi RK1 nodes as remote build machines. Keep
      disabled until at least one rk1 node has an NVMe-backed /nix/store (their eMMC is too
      small to build Pi sd-images) — see the header of this file and hosts/rk1/nvme.nix
    '';

    enabledNodes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "rk1a"
        "rk1b"
      ];
      example = [ "rk1b" ];
      description = ''
        Which rk1 nodes to register as builders. List ONLY nodes with an NVMe-backed
        /nix/store; an eMMC-only node would fail Pi sd-image builds with ENOSPC. Currently
        only rk1b qualifies.
      '';
    };

    sshKey = lib.mkOption {
      type = lib.types.str;
      default = "/home/inkpotmonkey/.ssh/id_ed25519";
      description = ''
        Path on the build host to the SSH private key the nix-daemon (root) uses to reach
        the rk1 nodes as inkpotmonkey. Root can read it; the matching public key is already
        authorised on the rk1 nodes via secrets/identities.nix.
      '';
    };

    maxJobs = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = ''
        Concurrent build jobs per rk1 node. Kept low so image builds don't starve the
        llama.cpp model serving the rk1 nodes are primarily there for.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    nix.distributedBuilds = true;
    # Let the rk1 builders fetch substitutable deps directly instead of copying everything
    # from the build host first.
    nix.settings.builders-use-substitutes = true;

    nix.buildMachines = map (n: {
      inherit (n) hostName publicHostKey;
      inherit (cfg) sshKey maxJobs;
      sshUser = "inkpotmonkey";
      systems = [ "aarch64-linux" ];
      protocol = "ssh-ng";
      speedFactor = 1;
      supportedFeatures = [
        "big-parallel"
        "kvm"
      ];
    }) (lib.filter (n: lib.elem n.hostName cfg.enabledNodes) nodes);
  };
}
