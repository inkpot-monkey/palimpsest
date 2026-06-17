{
  config,
  lib,
  inputs,
  ...
}:

let
  cfg = config.custom.profiles.pi;
in
{
  imports = [
    inputs.nixos-raspberrypi.nixosModules.raspberry-pi-4.base
    inputs.nixos-raspberrypi.nixosModules.sd-image
    inputs.nixos-raspberrypi.nixosModules.trusted-nix-caches
  ];

  # Declared here, with its implementation. The pi profile is excluded from the
  # universal bundle, so this option is undeclared on non-Pi hosts — readers must
  # guard with `config.custom.profiles.pi.enable or false` (see nixConfig.nix).
  options.custom.profiles.pi.enable = lib.mkEnableOption "Raspberry Pi specific configuration";

  config = lib.mkIf cfg.enable {
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
  };
}
