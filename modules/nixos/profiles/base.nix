{
  config,
  lib,
  options,
  pkgs,
  inputs,
  settings,
  ...
}:
let
  cfg = config.custom.profiles.base;

  # journald defaults to 10% of the filesystem it sits on, which is sized for a machine
  # whose journal IS the record. Here it is not: every host ships its journal to
  # VictoriaLogs via Vector (profiles/monitoring/client.nix) with 30-day retention
  # (ADR-0021), so the local copy is a buffer for a Vector outage and for `journalctl` on
  # the box. Uncapped, that duplicate cost 2.8 GiB on rk1b — 10% of a 29 GiB eMMC card,
  # and the second-largest consumer on it. The cap is uniform because the local journal's
  # PURPOSE is uniform, unlike disk headroom (see diskFloorGiB, which is per host because
  # the workloads genuinely differ).
  #
  # nixpkgs renamed the journald knob: `services.journald.extraConfig` (a raw .conf blob) became
  # `services.journald.settings.<section>.<key>`, and the old name is now a hard assertion rather
  # than a deprecation warning. This profile is imported by hosts on TWO different nixpkgs pins —
  # porcupineFish rides nixos-raspberrypi's older one, which has only the old name — so neither
  # spelling works everywhere. Write whichever the evaluating pin actually offers.
  journalSizeCap =
    if options.services.journald ? settings then
      { services.journald.settings.Journal.SystemMaxUse = "512M"; }
    else
      { services.journald.extraConfig = "SystemMaxUse=512M"; };
in
{
  imports = [
    # Host-side system wiring for the contract (its ADR-0004): import the contract's umbrella
    # nixos kit (the `contract.users` schema, realization, feature modules, insecure aggregator,
    # exposed-host ban — all closed over the registry). The contract leaves only the platform
    # binding to the host, and that seam is home-side now (modules/homeManager/options.nix), so
    # this is pure glue. (Was users/identity.nix, inlined here when the in-tree users/ dir went.)
    inputs.contract.nixosModules.default
    # The host's display binding. The contract is display-server-agnostic (contract ADR-0021):
    # it only says a gui surface is needed (`contract.display.enabled`); this host renders a
    # WAYLAND SDDM + Plasma 6 seat. Swap this module to change desktop environment / session type;
    # the contract is unchanged. Self-gated on `contract.display.enabled`, so inert on non-gui hosts.
    # (Also carries the host-opt-in desktop plumbing behind custom.profiles.gui.enable — see
    # the header of gui.nix for why the two gates stay separate.)
    ./gui.nix
  ];

  options.custom.profiles = {
    base.enable = lib.mkEnableOption "base system configuration";
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      journalSizeCap
      {
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

        # Fleet host keys, so any host-to-host ssh/rsync/scp works without a first-contact
        # prompt. MagicDNS already resolves every peer by name; what it does not do is
        # vouch for the machine answering, and that is the half OpenSSH refuses on. Without
        # this, an interactive run stops at "authenticity of host ... can't be established"
        # and a scripted one dies outright with "Host key verification failed" — which is
        # exactly how an rsync from kelpy to rk1b failed even though the name resolved.
        #
        # Declared rather than trust-on-first-use deliberately: TOFU records whatever
        # answered the first time, which is only as trustworthy as that moment. These come
        # from the hosts themselves and live in the repo, so a changed key is a visible
        # diff instead of a silent re-pin.
        #
        # Lives in `base` (fleet-wide) rather than the `ssh` profile, which only the
        # servers enable — the desktops initiate most of these connections and would
        # otherwise be the machines still prompting.
        programs.ssh.knownHosts = {
          # Trusted backup targets fleet-wide.
          "zh2046.rsync.net".publicKey =
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJtclizeBy1Uo3D86HpgD3LONGVH0CJ0NT+YfZlldAJd";
        }
        // lib.mapAttrs (host: key: {
          publicKey = key;
          # Tailscale lowercases MagicDNS names, so `sawtoothShark` is `sawtoothshark`
          # on the tailnet while the Nix attribute keeps its camelCase. Accept both
          # spellings and the FQDN, or half the ways of naming a host still prompt.
          hostNames = lib.unique [
            host
            (lib.toLower host)
            "${host}.${settings.tailnet}"
            "${lib.toLower host}.${settings.tailnet}"
          ];
        }) settings.hostKeys;
      }
    ]
  );
}
