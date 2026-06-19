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
    # Native aarch64 remote builder (rk1b — it has the NVMe-backed /nix/store; rk1a is
    # eMMC-only and stays out via enabledNodes below).
    self.nixosProfiles.piBuilder
  ];

  custom.profiles = {
    base.enable = true;
    sudo.enable = true;
    audio.enable = true;
    gui-base.enable = true;
    kanata.enable = true; # keyboard remap, host-side (ADR-0018 slice 11)
    backup.enable = false;
    direnv.enable = true;
    fonts.enable = true;
    gaming.enable = false;
    bluetooth.enable = true;
    impermanence.enable = false;
    litellm.enable = false;
    monitoring-client.enable = false;
    # rk1b now has an NVMe-backed /nix/store, so it serves as the fleet's native aarch64
    # remote builder (sd-images build there instead of under local QEMU). rk1a is eMMC-only
    # and excluded via enabledNodes. See modules/nixos/profiles/pi-builder.nix + hosts/rk1/nvme.nix.
    piBuilder.enable = true;
    piBuilder.enabledNodes = [ "rk1b" ];
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

  # Grant-as-data (ADR-0018, slice 10): the host grants inkpotmonkey's features
  # explicitly, rather than the user self-granting via a `.gui` variant import. gui +
  # workstation reproduce what the old gui variant conferred.
  custom.users.inkpotmonkey.granted = {
    gui.enable = true;
    workstation.enable = true;
    # virtualization groups, split out of gui (ADR-0018 slice 11) — reproduces what
    # the gui block conferred here before the split.
    virtualization.enable = true;
    # signing key for commit signing (ADR-0018 slice 13), replacing the hostName gate.
    signing.enable = true;
  };

  system.stateVersion = "25.11";
}
