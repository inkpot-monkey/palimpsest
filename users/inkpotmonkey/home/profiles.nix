{ lib, hostFacts, ... }:
let
  isGui = hostFacts.granted.gui.enable;
in
{
  # The desktop/dev home modules use newer home-manager options that don't exist
  # in the home-manager release the pi hosts pin (home-manager-25_11). Import
  # them ONLY on gui hosts: `lib.mkIf` cannot suppress "option does not exist"
  # errors for a disabled-but-imported module (unknown-option checks run during
  # structural name-collection, before the condition), so headless (cli) hosts —
  # e.g. porcupineFish on home-manager-25_11 — must not import these at all.
  # See hosts/porcupineFish/README.md for the full rationale.
  #
  # We branch on the restricted `hostFacts` projection (ADR-0018, slice 12) rather
  # than this module's own `config` (which would recurse, since imports determine
  # config) or raw `osConfig` (which exposes the whole system tree). `signing.nix`/
  # `git-annex.nix` carry no version-specific options and stay importable everywhere
  # (opt-in per host via their own enable option).
  imports = [
    ./signing.nix
    ./git-annex.nix
  ]
  ++ lib.optionals isGui [
    ./gui.nix
    ./dev.nix
    ./ai/default.nix
    ./emacs/default.nix
    # Enables for the gui-only modules live here so they are only set where the
    # modules that declare them are imported. cli/gui enables are set centrally
    # in users/inkpotmonkey/nixos/default.nix.
    {
      custom.home.profiles = {
        dev.enable = lib.mkDefault true;
        ai.enable = lib.mkDefault true;
        emacs.enable = lib.mkDefault true;
      };
    }
  ];
}
