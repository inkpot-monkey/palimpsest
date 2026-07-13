# Shared configuration for both Turing Pi RK1 (RK3588, 32 GB) nodes.
# Per-node differences (hostname + model) are set in hosts/default.nix.
{
  config,
  inputs,
  lib,
  self,
  ...
}:
{
  imports = [
    # Hardware: boot, u-boot, mainline kernel, device tree, root fileSystem.
    inputs.nixos-turing-rk1.nixosModules.turing-rk1

    # RK1-specific local module (not a shared profile — only these nodes use the NVMe cache).
    ./nvme.nix # optional NVMe model-cache storage (inert until custom.rk1.nvme.enable = true)
    # Home Assistant + Wyoming voice is now the shared `homeassistant` profile (in the
    # bundle below); rk1b enables it via custom.profiles.homeassistant in hosts/default.nix.

    # The same kitchen-sink bundle every other host uses. Features stay OFF unless toggled
    # in `custom.profiles` below; disabled profiles are mkIf-gated no-ops, so importing the
    # whole bundle is behaviour-neutral versus the old à-la-carte list (verified: identical
    # system fingerprint — same packages, etc entries, systemd units, enable flags) and it
    # removes the manual transitive-import tracking (e.g. tailscale reading
    # custom.profiles.impermanence.enable). See docs/adr/0013.
    self.nixosProfiles.bundle
  ];

  custom.profiles = {
    base.enable = true;
    impermanence.enable = true;
    ssh.enable = true;
    sudo.enable = true;
    tailscale = {
      enable = true;
      tags = [ "tag:server" ];
    };
  };

  # tmpfs root — the eMMC (NIXOS_SD) becomes /persistent. The turing-rk1 hardware module
  # sets / to NIXOS_SD by default; override that here so the eMMC holds only declared
  # persistent state. NVMe partitions (nixstore, rk1cache) are unaffected.
  fileSystems."/" = lib.mkForce {
    device = "none";
    fsType = "tmpfs";
    options = [
      "defaults"
      "size=2G"
      "mode=755"
    ];
  };

  # The turing-rk1 hardware module uses lib.mkForce (priority 50) on boot.kernelParams to
  # add `root=UUID=...` and `rootfstype=ext4`. With a tmpfs root those are wrong AND they
  # cause systemd-fstab-generator in the initrd to generate a second sysroot.mount unit
  # alongside the one derived from fileSystems."/" above — "Duplicate entry in initrd-fstab".
  # lib.mkOverride 49 (priority 49) beats mkForce (50) so we can strip those params here.
  boot.kernelParams = lib.mkOverride 49 [
    "console=ttyS0,115200"
    "loglevel=7"
  ];
  fileSystems."/persistent" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
    neededForBoot = true;
  };
  # When /nix is NOT on a separate NVMe nixstore partition (i.e. rk1a), bind it
  # from the persistent eMMC so the Nix store is reachable from the tmpfs root.
  # On rk1b, nvme.nix sets fileSystems."/nix" to the NVMe nixstore and this is skipped.
  fileSystems."/nix" = lib.mkIf (!config.custom.rk1.nvme.relocateNixStore) {
    device = "/persistent/nix";
    fsType = "none";
    options = [ "bind" ];
    depends = [ "/persistent" ];
    neededForBoot = true;
  };

  # /boot lives on the eMMC root partition (NIXOS_SD), not a separate FAT partition.
  # With tmpfs root, the bootloader install writes to the tmpfs /boot and the update
  # is lost on reboot unless /boot is bind-mounted from /persistent. u-boot reads the
  # extlinux.conf directly from the eMMC block device, so the bind-mount is what makes
  # updates durably visible to the bootloader.
  environment.persistence."/persistent".directories = [ "/boot" ];

  hardware.deviceTree.enable = true;

  # Declared users are authoritative: removes the GiyoMoon base-image `nixos`/`turing`
  # account on the first switch. Login is key-only SSH as inkpotmonkey (see profiles/ssh.nix);
  # inkpotmonkey's hashedPassword + ssh key come from secrets/identities.nix.
  users.mutableUsers = false;
  users.users.root.hashedPassword = "!"; # lock the root account (no password login)

  nixpkgs.hostPlatform = "aarch64-linux";

  system.stateVersion = "25.11";
}
