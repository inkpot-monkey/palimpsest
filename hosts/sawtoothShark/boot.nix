_: {
  # Bootloader
  boot = {
    loader = {
      systemd-boot = {
        enable = true;
        configurationLimit = 10;
      };
      efi.canTouchEfiVariables = true;
    };

    # System stability
    kernel.sysctl."kernel.sysrq" = 1;
  };

  # SSD optimization
  services.fstrim.enable = true;
}
