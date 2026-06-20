{
  self,
  inputs,
  ...
}:

{
  imports = [
    # Hardware
    ./hardware-configuration.nix
    inputs.nixos-hardware.nixosModules.framework-11th-gen-intel

    # Profiles
    self.nixosProfiles.bundle
  ];

  custom.profiles = {
    base.enable = true;
    audio.enable = true;
    wireless.enable = true;
    gui-base.enable = true;
    kanata.enable = true; # keyboard remap, host-side (ADR-0018 slice 11)
    bluetooth.enable = true;
    sops.enable = true;
    fonts.enable = true;
    tailscale = {
      enable = true;
      acceptDns = true;
    };
  };

  # User grants live in the fleet grant matrix (hosts/default.nix), not here.

  # weedySeadragon hosts two gui users (inkpotmonkey Wayland + eyeofalligator X11).
  # The display surface is NOT set here — it is derived from the union of each
  # granted gui user's `gui.session` by the contract realization (ADR-0019), so
  # both session types are offered and each user logs into their own.

  sops = {
    age.sshKeyPaths = [ "/home/inkpotmonkey/.ssh/id_ed25519" ];
  };

  # Safety Measure: Admin User
  custom.users.admin.identity = {
    username = "admin";
    name = "System Administrator";
    email = "admin@weedySeadragon.local";
    hashedPassword = "$6$Va8FcJEH8x9Hp/iL$EV3Nu3p9jqjin6rhbdQujHcX4LIsuxuzQOSfALpNqAO.LlZXNX/0EadRCfKx4FzqOKKUMGs6Ff4v8yarWjEpY1";
    profile = "cli";
    extraGroups = [
      "wheel"
      "networkmanager"
    ];
  };

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.efi.efiSysMountPoint = "/boot/efi";

  networking.hostName = "weedySeadragon";

  # Give weedySeadragon the power to cross compile for raspberry pis
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
  nixpkgs.buildPlatform.system = "x86_64-linux";

  # Power management for Framework laptop
  # power-profiles-daemon integrates better with KDE than TLP
  services.power-profiles-daemon.enable = true;

  # Network device discovery (mDNS)
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  system.stateVersion = "25.11";

  nixpkgs.config.permittedInsecurePackages = [
    "beekeeper-studio-5.5.7"
  ];
}
