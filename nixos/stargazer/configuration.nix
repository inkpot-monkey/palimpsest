# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{
  config,
  self,
  inputs,
  pkgs,
  ...
}:
let
  name = "stargazer";
in
{
  imports = [
    inputs.sops-nix.nixosModules.sops

    # Include the results of the hardware scan.
    ./hardware-configuration.nix

    ../common/default.nix
    ../common/nix.nix
    # TODO: automate
    ../common/users.nix
    ./zsa.nix

    ./vm.nix
    ./containers.nix

    # ../common/nebula.nix
    # ../common/listener.nix
  ];

  sops = {
    age.keyFile = "/home/inkpotmonkey/.config/sops/age/keys.txt";
    defaultSopsFile = self + "/secrets/secrets.yaml";
  };

  nix = {
    extraOptions = ''
      # Yet to reach master
      # use-xdg-base-directories = true
      keep-outputs = true
      keep-derivations = true
      experimental-features = nix-command flakes recursive-nix
    '';
  };

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.efi.efiSysMountPoint = "/boot/efi";

  networking.hostName = name;

  # Enable networking
  networking.networkmanager.enable = true;

  # Set your time zone.
  time.timeZone = "Europe/London";

  # Select internationalisation properties.
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

  # Enable the X11 windowing system.
  services.xserver.enable = true;

  # Enable the GNOME Desktop Environment.
  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;

  # Configure keymap in X11
  services.xserver = {
    xkb.layout = "us";
    xkb.variant = "";
  };

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Enable touchpad support (enabled default in most desktopManager).
  services.libinput.enable = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    coreutils
    binutils
    iputils
    dnsutils
    git
    curl
    wget
    ripgrep
    fd
    jq

    # Add man pages for syscalls
    man-pages
    man-pages-posix

    cntr

    gnome-network-displays

    ## https://wiki.nixos.org/wiki/GStreamer
    # Video/Audio data composition framework tools like "gst-inspect", "gst-launch" ...
    gst_all_1.gstreamer
    # Common plugins like "filesrc" to combine within e.g. gst-launch
    gst_all_1.gst-plugins-base
    # Specialized plugins separated by quality
    gst_all_1.gst-plugins-good
    gst_all_1.gst-plugins-bad
    gst_all_1.gst-plugins-ugly
    # Plugins to reuse ffmpeg to play almost every video format
    gst_all_1.gst-libav
    # Support the Video Audio (Hardware) Acceleration API
    gst_all_1.gst-vaapi

    ifuse
    libimobiledevice
    libimobiledevice-glue
  ];

  services.usbmuxd.enable = true;

  # As this is a user facing machine add documentation
  documentation = {
    enable = true;
    man = {
      enable = true;
      # allows searching :)
      generateCaches = true;
    };
    doc.enable = true;
    dev.enable = true;
    info.enable = true;
  };

  # Allow using hardware ledgers
  hardware.ledger.enable = true;

  # Allow kanata to be run as user
  # Kanata is keybinding
  services.udev.extraRules = ''
    KERNEL=="uinput", MODE="0660", GROUP="uinput", OPTIONS+="static_node=uinput"
  '';
  boot.kernelModules = [ "uinput" ];

  hardware.logitech.wireless.enable = true;
  hardware.logitech.wireless.enableGraphical = true;

  # This doesnt work with flakes and is replaced with nix-index in the home manager module
  programs.command-not-found.enable = false;

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

  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true; # Open ports in the firewall for Steam Remote Play
    dedicatedServer.openFirewall = true; # Open ports in the firewall for Source Dedicated Server
  };

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  programs.mtr.enable = true;

  # List services that you want to enable:

  # Or disable the firewall altogether.
  networking.firewall.enable = false;

  # Give stargazer the power to cross compile for raspberry pis
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
  nixpkgs.buildPlatform.system = "x86_64-linux";

  # Stop the grey screen of purgatory
  # https://discourse.nixos.org/t/gnome-session-sometimes-fails-to-load-after-login-unless-wifi-is-disabled-from-login-screen/38771/4
  services.tlp.settings.DEVICES_TO_DISABLE_ON_STARTUP = "bluetooth";

  system.stateVersion = "25.05";

}
