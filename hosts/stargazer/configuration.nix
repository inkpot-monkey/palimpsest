{
  self,
  inputs,
  ...
}:

{
  # =========================================
  # Imports
  # =========================================
  imports = [
    inputs.disko.nixosModules.disko
    inputs.nixos-hardware.nixosModules.framework-13-7040-amd

    # Hardware & Boot
    ./hardware-configuration.nix
    ./boot.nix

    # Machine Specific Modules
    ./ai.nix

    # Profiles
    self.nixosProfiles.base
    self.nixosProfiles.audio
    self.nixosProfiles.wireless
    self.nixosProfiles.gui-base
    self.nixosProfiles.gaming
    self.nixosProfiles.virtualization
    self.nixosProfiles.fonts
    self.nixosProfiles.sops
    self.nixosProfiles.regreet
    self.nixosProfiles.bluetooth
    self.nixosProfiles.zsa
    self.nixosProfiles.tailscale
    self.nixosProfiles.monitoring.client
    self.nixosProfiles.monitoring.smartctl
  ];

  system.stateVersion = "25.05";

  # Disable command-not-found (handled by nix-index in home-manager)
  programs.command-not-found.enable = false;

  # Secrets Management
  sops = {
    age.sshKeyPaths = [
      "/home/inkpotmonkey/.ssh/id_ed25519"
      "/etc/ssh/ssh_host_ed25519_key"
    ];
  };

  # =========================================
  # Hardware & Power Management
  # =========================================

  # Graphics
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  # Peripherals
  hardware.ledger.enable = true; # Hardware wallets
  hardware.logitech.wireless.enable = true;
  hardware.logitech.wireless.enableGraphical = true;

  # Input configuration (Kanata / uinput)
  services.udev.extraRules = ''
    KERNEL=="uinput", MODE="0660", GROUP="uinput", OPTIONS+="static_node=uinput"
  '';

  # =========================================
  # Networking
  # =========================================
  networking.hostName = "stargazer";
  nixpkgs.hostPlatform = "x86_64-linux";
  networking.firewall.enable = true;

  programs.mtr.enable = true; # Network diagnostic tool
  programs.nix-ld.enable = true; # Run unpatched dynamic binaries on NixOS
}
