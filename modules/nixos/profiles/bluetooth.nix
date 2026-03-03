{ ... }:

{
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  # Generic Bluetooth management tool (GUI)
  services.blueman.enable = true;
}
