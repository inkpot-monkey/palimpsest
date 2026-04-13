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
  ];

  custom.profiles = {
    base.enable = true;
    audio.enable = true;
    gui-base.enable = true;
    backup.enable = false;
    direnv.enable = true;
    fonts.enable = true;
    gaming.enable = false;
    impermanence.enable = false;
    litellm.enable = false;
    monitoring-client.enable = false;
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

  sops.age.sshKeyPaths = [
    "/home/inkpotmonkey/.ssh/id_ed25519"
    # "/etc/ssh/ssh_host_ed25519_key"
  ];

  # services.restic.backups.daily.paths = lib.mkIf config.custom.profiles.backup.enable [ "/persist" ];

  networking.hostName = "sawtoothShark";
  nixpkgs = {
    hostPlatform = "x86_64-linux";
    overlays = [ inputs.emacs-overlay.overlays.default ];
  };

  # Input configuration (Kanata / uinput)
  services.udev.extraRules = ''
    KERNEL=="uinput", MODE="0660", GROUP="uinput", OPTIONS+="static_node=uinput"
  '';

  users.users.inkpotmonkey.extraGroups = [ "uinput" ];

  system.stateVersion = "25.11";
}
