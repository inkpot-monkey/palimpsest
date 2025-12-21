# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{
  self,
  inputs,
  pkgs,
  ...
}:

let
  name = "stargazer";
in
{
  # =========================================
  # Imports
  # =========================================
  imports = [
    inputs.sops-nix.nixosModules.sops

    # Hardware & Boot
    ./hardware-configuration.nix
    ./boot.nix
    ./audio.nix

    # Desktop & Login (Added)
    ./login.nix

    # Shared Modules
    ../common/default.nix
    ../common/nix.nix
    # TODO: automate
    ../common/users.nix

    # Machine Specific Modules
    ./zsa.nix
    ./vm.nix
    ./containers.nix
    ./screencast.nix

    # ../common/nebula.nix
    # ../common/listener.nix
  ];

  # =========================================
  # Nix & System Settings
  # =========================================
  system.stateVersion = "25.05";

  # Allow unfree or insecure packages if necessary
  nixpkgs.config.permittedInsecurePackages = [
    "beekeeper-studio-5.3.4"
  ];

  # Disable command-not-found (handled by nix-index in home-manager)
  programs.command-not-found.enable = false;

  # Secrets Management
  sops = {
    age.keyFile = "/home/inkpotmonkey/.config/sops/age/keys.txt";
    defaultSopsFile = self + "/secrets/secrets.yaml";
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
  networking.hostName = name;
  networking.networkmanager.enable = true;
  networking.firewall.enable = true;

  networking.hosts = {
    "37.205.14.206" = [ "kelpy" ];
  };

  programs.mtr.enable = true; # Network diagnostic tool

  # =========================================
  # Localization & Time
  # =========================================
  time.timeZone = "Europe/Madrid";
  i18n.defaultLocale = "en_GB.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_GB.UTF-8";
    LC_IDENTIFICATION = "en_GB.UTF-8";
    LC_MEASUREMENT = "en_GB.UTF-8";
    LC_MONETARY = "en_GB.UTF-8";
    LC_NAME = "en_GB.UTF-8";
    LC_NUMERIC = "en_GB.UTF-8";
    LC_PAPER = "en_GB.UTF-8";
    LC_TELEPHONE = "en_GB.UTF-8";
    LC_TIME = "en_GB.UTF-8";
  };

  # =========================================
  # Desktop Environment (Base X11/Wayland)
  # =========================================
  services.xserver = {
    enable = true;
    xkb.layout = "us";
    xkb.variant = "";
  };

  # Input Devices (Touchpad)
  services.libinput.enable = true;

  # Fonts
  fonts = {
    packages = with pkgs; [
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-color-emoji
      noto-fonts-monochrome-emoji
      symbola
      nerd-fonts.symbols-only
    ];
    enableDefaultPackages = true;
    fontDir.enable = true;
    fontconfig = {
      enable = true;
      antialias = true;
      defaultFonts = {
        serif = [ "Noto Serif" ];
        sansSerif = [ "Noto Sans" ];
        monospace = [ "Noto Sans Mono" ];
        emoji = [ "Noto Color Emoji" ];
      };
    };
  };

  # Security
  security.polkit.enable = true;

  # =========================================
  # Services
  # =========================================

  # Printing
  services.printing.enable = true;

  # iOS Device Support
  services.usbmuxd.enable = true;

  # Geolocation Service
  services.geoclue2.enable = true;

  # Power
  services.upower.enable = true;

  # =========================================
  # Programs & Games
  # =========================================
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
    dedicatedServer.openFirewall = true;
  };

  # Documentation
  documentation = {
    enable = true;
    man = {
      enable = true;
      generateCaches = true; # Allows searching man pages
    };
    doc.enable = true;
    dev.enable = true;
    info.enable = true;
  };

  # =========================================
  # System Packages
  # =========================================
  environment.systemPackages = with pkgs; [
    # Core Utilities
    coreutils
    binutils
    iputils
    dnsutils
    curl
    wget
    ripgrep
    fd
    jq
    git
    cntr

    # Man pages
    man-pages
    man-pages-posix

    # iOS Tools
    ifuse
    libimobiledevice
    libimobiledevice-glue

    # Multimedia / GStreamer
    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
    gst_all_1.gst-plugins-good
    gst_all_1.gst-plugins-bad
    gst_all_1.gst-plugins-ugly
    gst_all_1.gst-libav
    gst_all_1.gst-vaapi
  ];
}
