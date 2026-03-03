# Dell Latitude 7490 specific hardware configuration
{ pkgs, ... }:
{
  # Bootloader
  # Bootloader
  boot = {
    loader = {
      systemd-boot = {
        enable = true;
        configurationLimit = 10;
      };
      efi.canTouchEfiVariables = true;
    };

    # Kernel Parameters for Stability (Dell Latitude 7490)
    kernel.sysctl."kernel.sysrq" = 1;
    kernelParams = [
      "intel_idle.max_cstate=1"
      "i915.enable_dc=0"
      "i915.enable_psr=0"
      "acpi_backlight=native"
    ];
  };

  # SSD optimization
  services.fstrim.enable = true;

  # Hardware
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  # Remap CapsLock to Ctrl/Esc
  services.interception-tools = {
    enable = true;
    plugins = [ pkgs.interception-tools-plugins.dual-function-keys ];
    udevmonConfig = ''
      - JOB: "${pkgs.interception-tools}/bin/intercept -g $DEVNODE | ${pkgs.interception-tools-plugins.dual-function-keys}/bin/dual-function-keys -c /etc/dual-function-keys.yaml | ${pkgs.interception-tools}/bin/uinput -d $DEVNODE"
        DEVICE:
          EVENTS:
            EV_KEY: [KEY_CAPSLOCK]
    '';
  };

  environment.etc."dual-function-keys.yaml".text = ''
    MAPPINGS:
      - KEY: KEY_CAPSLOCK
        TAP: KEY_ESC
        HOLD: KEY_LEFTCTRL
  '';
}
