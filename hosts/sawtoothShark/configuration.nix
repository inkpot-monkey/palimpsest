{
  self,
  inputs,
  pkgs,
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

  # Run unpatched dynamic binaries on NixOS. Claude Desktop's Cowork feature
  # downloads a generic-glibc Claude Code CLI at runtime (~/.config/Claude/
  # claude-code/) that expects /lib64/ld-linux-x86-64.so.2; nix-ld supplies it.
  programs.nix-ld.enable = true;

  # Claude Desktop's Cowork shells out to system tools through hardcoded FHS
  # paths (/usr/bin/git, /bin/bash, /usr/bin/curl, …) — its exec-capability
  # registry never consults $PATH, so on NixOS those lookups miss and tasks die
  # with "bash not found" / exit code 127. envfs mounts a FUSE /bin and
  # /usr/bin that resolves any binary on the SYSTEM PATH on demand, satisfying
  # the lookups (it keeps the stock /bin/sh and /usr/bin/env).
  services.envfs.enable = true;

  # envfs only exposes binaries that are in the system profile. Cowork's
  # registry expects git, notify-send (libnotify) and gdbus (glib), which were
  # otherwise only in inkpotmonkey's per-user profile (curl/which/xdg-open/
  # xdg-mime are already system-wide). Add them so /usr/bin/<tool> resolves.
  environment.systemPackages = with pkgs; [
    git
    libnotify
    glib
    gnome-network-displays
  ];

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

  # User grants live in the fleet grant matrix (hosts/default.nix), not here.

  system.stateVersion = "25.11";
}
