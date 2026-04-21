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

    kernelModules = [ "hid_magicmouse" ]; # Full support for Apple Magic Trackpad
    kernelParams = [
      # Fix for "hci0: Reading supported features failed (-16)" on Intel adapters
      "btintel.enable_status_tracking=0"
      "btusb.enable_autosuspend=n" # Prevent Bluetooth from going to sleep
    ];
  };

  # SSD optimization
  services.fstrim.enable = true;
}
