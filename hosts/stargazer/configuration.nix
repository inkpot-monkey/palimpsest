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
    inputs.nixos-hardware.nixosModules.framework-amd-ai-300-series

    # Hardware & Boot
    ./hardware-configuration.nix
    ./boot.nix

    # Machine Specific Modules
    ./ai.nix

    # Profiles
    self.nixosProfiles.bundle
  ];

  custom.profiles = {
    base.enable = true;
    audio.enable = true;
    wireless.enable = true;
    gui-base.enable = true;
    gaming.enable = true;
    virtualization.enable = true;
    fonts.enable = true;
    regreet.enable = true;
    bluetooth.enable = true;
    zsa.enable = true;
    tailscale = {
      enable = true;
      acceptDns = true;
    };
    monitoring-client.enable = true;
    monitoring-smartctl.enable = true;
  };

  services.transcription-node = {
    enable = true;
    listenAddress = "100.95.39.9";
  };

  system.stateVersion = "25.05";

  # Disable command-not-found (handled by nix-index in home-manager)
  programs.command-not-found.enable = false;

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
