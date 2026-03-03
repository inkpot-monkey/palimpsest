{
  self,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    self.nixosProfiles.nixConfig
  ];

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
}
