{ config, pkgs, ... }:

{
  # =========================================
  # Kernel & Modules
  # =========================================
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.kernelModules = [
    "uinput"
  ];
  boot.kernelParams = [
    "amdgpu.gttsize=32768" # Boost GTT size for LLMs (32GB - Half of system RAM)
    "ttm.pages_limit=8388608" # Increase pool size for better memory management
    "ttm.page_pool_size=8388608"
  ];

  # =========================================
  # Bootloader (Systemd-boot)
  # =========================================
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # =========================================
  # Encryption & TPM
  # =========================================
  boot.initrd.systemd.enable = true;
  boot.initrd.availableKernelModules = [
    "tpm_crb"
    "tpm_tis"
  ];

  # TPM Unlocking Config
  boot.initrd.luks.devices."crypted".crypttabExtraOpts = [ "tpm2-device=auto" ];

  # TPM Maintenance Alias
  environment.shellAliases = {
    tpm-update =
      let
        drive = config.boot.initrd.luks.devices."crypted".device;
      in
      "sudo systemd-cryptenroll ${drive} --wipe-slot=tpm2 && sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+2+7 ${drive}";
  };

  # =========================================
  # System Architecture & Firmware
  # =========================================
  # Give stargazer the power to cross compile for raspberry pis
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
  nixpkgs.buildPlatform.system = "x86_64-linux";

  # Firmware updates
  hardware.enableAllFirmware = true;
}
