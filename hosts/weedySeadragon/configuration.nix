{
  config,
  self,
  inputs,
  pkgs,
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
    bluetooth.enable = true;
    sops.enable = true;
    fonts.enable = true;
    tailscale = {
      enable = true;
      acceptDns = true;
    };
  };

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
