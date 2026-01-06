{
  pkgs,
  inputs,
  config,
  lib,
  ...
}:
{
  imports = [
    inputs.nixos-raspberrypi.nixosModules.raspberry-pi-4.base
    inputs.nixos-raspberrypi.nixosModules.trusted-nix-caches
  ];

  # ==========================================
  # Bootloader & Filesystem
  # ==========================================
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  # Required for uboot-builder updates
  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/NIXOS_SD";
      fsType = "ext4";
      autoResize = true;
      options = [ "noatime" ];
    };
    "/boot/firmware" = {
      device = "/dev/disk/by-label/FIRMWARE";
      fsType = "vfat";
      options = [
        "fmask=0022"
        "dmask=0022"
      ];
    };
  };

  # ==========================================
  # Hardware & Power
  # ==========================================
  powerManagement.enable = false;
  hardware.enableRedistributableFirmware = true;

  # Specific to RPi4
  boot.kernelPackages = pkgs.linuxPackages_rpi4;

  # Optimization for low-memory devices
  zramSwap.enable = true;
}
