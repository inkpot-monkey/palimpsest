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
    ../options/identity.nix
  ];

  options.custom.profiles = {
    base.enable = lib.mkEnableOption "base system configuration";
    pi.enable = lib.mkEnableOption "Raspberry Pi specific configuration";
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
