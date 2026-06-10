# Use the Turing Pi RK1 nodes (rk1a/rk1b, RK3588, native aarch64) as remote build
# machines for the build host, so Pi sd-images build natively instead of under slow
# QEMU emulation.
#
# GATED OFF by default. The rk1 nodes currently boot from a 29 GB eMMC with no room to
# assemble a ~6.8 GB Pi sd-image (a native build there fails with "No space left on
# device"). Do NOT enable until they have an NVMe-backed /nix/store with headroom — see
# hosts/rk1/nvme.nix. Enable checklist:
#   1. Install NVMe drives in the rk1 compute modules; deploy hosts/rk1/nvme.nix.
#   2. Confirm `/nix/store` is on NVMe with >20 GB free on rk1a AND rk1b.
#   3. Set `custom.profiles.piBuilder.enable = true;` on the build host (sawtoothShark).
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
      offloading aarch64 builds to the Turing Pi RK1 nodes (rk1a/rk1b) as remote build
      machines. Keep disabled until the rk1 nodes have NVMe-backed /nix/store (their eMMC
      is too small to build Pi sd-images) — see the header of this file and hosts/rk1/nvme.nix
    '';

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
    }) nodes;
  };
}
