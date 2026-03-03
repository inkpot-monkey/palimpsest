{
  pkgs,
  lib,
  inputs,
  ...
}:
{
  imports = [
    inputs.nixos-raspberrypi.nixosModules.raspberry-pi-4.base
    inputs.nixos-raspberrypi.nixosModules.sd-image
    inputs.nixos-raspberrypi.nixosModules.trusted-nix-caches
  ];

  # ==========================================
  # Filesystem & Boot
  # ==========================================
  # We use the official bootloader and SD image settings from the nixos-raspberrypi module.
  # The module now defaults to a 1GB firmware partition (sdImage.firmwareSize = 1024).

  boot.loader.raspberry-pi.enable = true;

  # Standard Pi 4 Labels
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

  # Ensure the mount point exists on the root filesystem for the image builder
  systemd.tmpfiles.rules = [
    "d /boot/firmware 0755 root root -"
  ];

  # ==========================================
  # Hardware & Optimization
  # ==========================================
  hardware.enableRedistributableFirmware = true;
}
