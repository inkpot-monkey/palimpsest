{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.custom.profiles.base;
in
{
  imports = [
    ../../../users/identity.nix
    # The host's display binding for the contract's gui-session decision (ADR-0021
    # review): the contract decides which sessions to offer, this renders them with
    # SDDM + Plasma 6. Swap this module to change desktop environment; the contract is
    # unchanged. Self-gated on custom.gui.surface, so it's inert on non-gui hosts.
    ./gui-desktop.nix
  ];

  options.custom.profiles = {
    base.enable = lib.mkEnableOption "base system configuration";
  };

  config = lib.mkIf cfg.enable {
    custom.profiles = {
      nixConfig.enable = true;
      sops.enable = true;
    };

    # =========================================
    # Localization & Clock
    # =========================================
    time.timeZone = "Europe/Madrid";
    i18n.defaultLocale = "en_US.UTF-8";
    i18n.extraLocaleSettings = {
      LC_ADDRESS = "es_ES.UTF-8";
      LC_IDENTIFICATION = "es_ES.UTF-8";
      LC_MEASUREMENT = "es_ES.UTF-8";
      LC_MONETARY = "es_ES.UTF-8";
      LC_NAME = "es_ES.UTF-8";
      LC_NUMERIC = "es_ES.UTF-8";
      LC_PAPER = "es_ES.UTF-8";
      LC_TELEPHONE = "es_ES.UTF-8";
      LC_TIME = "es_ES.UTF-8";
    };

    # Console keymap
    console.keyMap = "uk";

    # =========================================
    # Core System Services
    # =========================================
    services = {
      resolved.enable = true;
      fwupd.enable = lib.mkDefault pkgs.stdenv.hostPlatform.isx86_64;
    };

    zramSwap.enable = true;

    # Trusted backup targets fleet-wide
    programs.ssh.knownHosts."zh2046.rsync.net".publicKey =
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJtclizeBy1Uo3D86HpgD3LONGVH0CJ0NT+YfZlldAJd";
  };
}
