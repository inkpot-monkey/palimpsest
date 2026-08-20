{
  config,
  pkgs,
  lib,
  inputs,
  self,
  ...
}:
{
  imports = [
    "${inputs.nixpkgs}/nixos/modules/profiles/headless.nix"

    # Profiles
    self.nixosProfiles.bundle
    self.nixosProfiles.pi-bundle

    # Impermanence (ephemeral tmpfs root). Deployed & verified 2026-07-06; still
    # boot-critical if you change it — see the file header. Remove this import to
    # fall back to the plain ext4-root config.
    ./impermanence.nix
  ];

  custom.profiles = {
    pi.enable = true;
    base.enable = true;
    ssh.enable = true;
    sudo.enable = true;
    wireless.enable = true;
    hifiberry.enable = true;
    hifi.enable = true;
    tailscale = {
      enable = true;
      advertiseSubnet = "192.168.1.0/24";
      tags = [ "tag:server" ];
    };
    monitoring-client.enable = true;
    monitoring-smartctl.enable = true;
    # Off fleet-wide: DEFERRED, not blocked (mirrors kelpy's note — rsync.net is reachable,
    # this is a scheduling decision; palimpsest#150). reportJobs keeps it on the Backups
    # board as a known-disabled edge.
    backup.enable = false;
    backup.reportJobs = [ "daily" ];
    # blocky removed (ADR-0023): this audio node's recovery is a cold power-cycle,
    # so it's a liability in the fastest-wins global-nameserver list. Fleet DNS is
    # now dual blocky on kelpy + rk1b.
  };

  # ZFS is a stray default and nothing on this audio node uses it — that alone is
  # reason to drop it. It also drags in the zfs-kernel module, which builds against
  # the kernel's `dev` output; that output is uncached upstream (nixos-raspberrypi
  # caches only `out`). `just cache-kernel porcupineFish` now pushes `dev` to our own
  # cache, so this no longer *forces* a full kernel recompile — but that relief is
  # conditional (it lapses on every kernel-pin bump until cache-kernel is re-run) and
  # the zfs module itself is still an uncached from-source build. So: keep it off.
  boot.supportedFilesystems.zfs = lib.mkForce false;

  # Gated at the job level (mirrors kelpy): with restic off, the `daily` job must not
  # exist at all, or the module fails on a job with paths but no password. mkIf on the
  # whole value omits the job; mkIf on `.paths` alone would still instantiate it.
  services.restic.backups.daily = lib.mkIf config.custom.profiles.backup.enable {
    paths = [
      "/var/lib"
      "/home/inkpotmonkey"
    ];
  };

  sops.age.sshKeyPaths = [
    "/etc/ssh/ssh_host_ed25519_key"
  ];

  environment.systemPackages = with pkgs; [
    git
  ];

  # Pin Vector to the fleet's version instead of the (older) one in nixos-raspberrypi's nixpkgs.
  # porcupineFish builds from that pinned nixpkgs (see the toolchain-pin notes) and so lags the
  # fleet — its Vector was 0.52 while the rest of the fleet runs 0.57. The shared monitoring
  # profile's VictoriaLogs sink uses `dangerously_allow_unconfined_template_resolution`, a field
  # that only exists in Vector 0.57+, so the older binary fails `vector validate` with "unknown
  # field" and blocks the whole system build. Rather than version-gate that shared config, keep
  # Vector uniform fleet-wide: take the fleet nixpkgs' 0.57 (cached aarch64 on cache.nixos.org, so
  # this substitutes — no from-source Rust build). This mirrors how other pi-nixpkgs-lag quirks
  # (zfs, the kernel) are quarantined here at the host level rather than leaking into shared code.
  services.vector.package = inputs.nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system}.vector;

  networking.hostName = "porcupineFish";

  system.stateVersion = "25.11";

  hardware.enableRedistributableFirmware = true;
}
