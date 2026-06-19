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
    sudo.enable = true;
    audio.enable = true;
    wireless.enable = true;
    gui-base.enable = true;
    gaming.enable = true;
    virtualization.enable = true;
    kanata.enable = true; # keyboard remap, host-side (ADR-0018 slice 11)
    fonts.enable = true;
    regreet.enable = false; # Disabled in favor of SDDM for Plasma 6
    bluetooth.enable = true;
    zsa.enable = true;
    tailscale = {
      enable = true;
      acceptDns = true;
    };
    monitoring-client.enable = true;
    monitoring-smartctl.enable = true;
  };

  # Grant-as-data: inkpotmonkey's virtualization groups (disk/libvirtd/qemu-libvirtd)
  # come from this grant, split out of gui (ADR-0018 slice 11). stargazer also runs
  # the virtualization *services* via custom.profiles.virtualization above.
  custom.users.inkpotmonkey.granted.virtualization.enable = true;

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
