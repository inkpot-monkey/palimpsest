{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.custom.profiles.base;
in
{
  imports = [
    # Host-side system wiring for the contract (its ADR-0004): import the contract's umbrella
    # nixos kit (the custom.users schema, realization, feature modules, insecure aggregator,
    # exposed-host ban — all closed over the registry). The contract leaves only the platform
    # binding to the host, and that seam is home-side now (modules/homeManager/options.nix), so
    # this is pure glue. (Was users/identity.nix, inlined here when the in-tree users/ dir went.)
    inputs.contract.nixosModules.default
    # The host's display binding. The contract is display-server-agnostic (contract ADR-0021):
    # it only says a gui surface is needed (custom.gui.surface.enabled); this host renders a
    # WAYLAND SDDM + Plasma 6 seat. Swap this module to change desktop environment / session type;
    # the contract is unchanged. Self-gated on custom.gui.surface.enabled, so inert on non-gui hosts.
    # (Also carries the host-opt-in desktop plumbing behind custom.profiles.gui.enable — see
    # the header of gui.nix for why the two gates stay separate.)
    ./gui.nix
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

    # /tmp is disk-backed on every host with a real root filesystem, and NixOS does not reap it
    # by default — so it is persistent storage that only ever grows. sawtoothShark had 6,151
    # entries there going back three months (30 GiB, one runaway file accounting for 23 GiB of
    # it) before anyone noticed. Reaping at boot is the cheapest possible guard; it is a no-op
    # on the hosts whose root is already a tmpfs (the impermanence Pis, kelpy's container).
    boot.tmp.cleanOnBoot = true;

    # Trusted backup targets fleet-wide
    programs.ssh.knownHosts."zh2046.rsync.net".publicKey =
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJtclizeBy1Uo3D86HpgD3LONGVH0CJ0NT+YfZlldAJd";
  };
}
