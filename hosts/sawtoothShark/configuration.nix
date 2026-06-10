{
  self,
  inputs,
  ...
}:
{
  imports = [
    # Hardware
    ./hardware-configuration.nix
    ./boot.nix
    inputs.nixos-hardware.nixosModules.dell-latitude-7490

    # Profiles
    self.nixosProfiles.bundle
    # Native aarch64 remote builders (rk1a/rk1b). Kept disabled until the rk1 nodes
    # have NVMe-backed /nix/store — their eMMC is too small to build Pi sd-images.
    self.nixosProfiles.piBuilder
  ];

  custom.profiles = {
    base.enable = true;
    sudo.enable = true;
    audio.enable = true;
    gui-base.enable = true;
    backup.enable = false;
    direnv.enable = true;
    fonts.enable = true;
    gaming.enable = false;
    bluetooth.enable = true;
    impermanence.enable = false;
    litellm.enable = false;
    monitoring-client.enable = false;
    # Flip to true only after the rk1 nodes have NVMe-backed /nix/store (see
    # modules/nixos/profiles/pi-builder.nix and hosts/rk1/nvme.nix).
    piBuilder.enable = false;
    tailscale = {
      enable = true;
      acceptDns = true;
    };
  };

  # Graphics
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  # Remap CapsLock to Ctrl/Esc
  # services.interception-tools = {
  #   enable = true;
  #   plugins = [ pkgs.interception-tools-plugins.dual-function-keys ];
  #   udevmonConfig = ''
  #     - JOB: "${pkgs.interception-tools}/bin/intercept -g $DEVNODE | ${pkgs.interception-tools-plugins.dual-function-keys}/bin/dual-function-keys -c /etc/dual-function-keys.yaml | ${pkgs.interception-tools}/bin/uinput -d $DEVNODE"
  #       DEVICE:
  #         EVENTS:
  #           EV_KEY: [KEY_CAPSLOCK]
  #   '';
  # };

  # environment.etc."dual-function-keys.yaml".text = ''
  #   MAPPINGS:
  #     - KEY: KEY_CAPSLOCK
  #       TAP: KEY_ESC
  #       HOLD: KEY_LEFTCTRL
  # '';

  # services.restic.backups.daily.paths = lib.mkIf config.custom.profiles.backup.enable [ "/persist" ];

  networking.hostName = "sawtoothShark";
  nixpkgs = {
    hostPlatform = "x86_64-linux";
  };

  # Give sawtoothShark the power to build images for the aarch64 raspberry
  # pis (e.g. porcupineFish SD images) locally via emulation, matching
  # stargazer (see hosts/stargazer/boot.nix).
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  # Input configuration (Kanata / uinput)
  services.udev.extraRules = ''
    KERNEL=="uinput", MODE="0660", GROUP="uinput", OPTIONS+="static_node=uinput"

    # Disable power management for Intel Bluetooth adapter
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="8087", ATTR{idProduct}=="0a2b", ATTR{power/control}="on"
  '';

  users.users.inkpotmonkey.extraGroups = [ "uinput" ];

  system.stateVersion = "25.11";
}
