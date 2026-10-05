{
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
    # A speaker on a shelf, not a laptop: keep the burned-in MAC everywhere and stop the
    # Livebox steering it between radios. 2.4 GHz measured better here than 5 GHz (-69 dBm
    # vs -76 dBm), so `bg` is the pin even though that inverts the usual advice — see the
    # option's description, and re-measure if the box or the router moves.
    wireless = {
      enable = true;
      mode = "stationary";
      band = "bg";
    };
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

  # WHAT this host would back up, declared ahead of `backup.enable` (still deferred,
  # palimpsest#150). The profile instantiates no restic unit until the job is enabled, so
  # unlike the old `services.restic.backups.daily` form this needs no `mkIf` to stay inert.
  custom.profiles.backup.jobs.daily.paths = [
    "/var/lib"
    "/home/inkpotmonkey"
  ];

  # Pin the kernel to a *stable*-tagged vendor bundle, never the input's default.
  #
  # nixos-raspberrypi's default kernel is currently linux_rpi-bcm2711-6.18.52, built from
  # raspberrypi/linux's `unstable_20260915` tag, and unstable/next-branch kernels hang this
  # host in the initrd before systemd ever starts -- a silent brick: no HDMI console (the
  # framebuffer only appears once vc4 KMS loads late), no network, and extlinux does not
  # fall back. The tell is a flashed card whose /var is empty and whose root was never
  # grown. See README "Toolchain pin".
  #
  # v6_18_39 is raspberrypi/linux `stable_20260724`, the newest stable bundle this input
  # offers, and it is a genuine 6.12 -> 6.18 LTS jump from the old 6.12.47 pin. Read the
  # TAG, not the version number, when changing this: 6.18.34 is stable_20260609 on this
  # rev but unstable_20260604 on main -- the same number, different branch.
  #
  # raspberry-pi-4.nix sets kernelPackages with mkDefault, so mkForce wins. A non-default
  # bundle is unlikely to be on nixos-raspberrypi.cachix.org; `just cache-kernel
  # porcupineFish` pre-seeds ours, and rk1b builds it natively rather than under QEMU.
  #
  # Mainline is not an option: the HiFiBerry machine driver and the
  # hifiberry-dacplusadcpro overlay are vendor-only.
  boot.kernelPackages = lib.mkForce pkgs.linuxAndFirmware.v6_18_39.linuxPackages_rpi4;

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
