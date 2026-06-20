# Home meta-profile options — part of the host↔user contract (ADR-0015).
# Consumed by modules/homeManager/options.nix to declare `custom.home.profiles.*`.
# The single home-profile vocabulary: meta-profiles (cli/gui) and the home-feature
# enables (restic/signing) whose home modules supply the matching config. Declaring
# them in one place keeps the vocabulary from scattering; the feature modules act on it.
{ lib }:
{
  cli.enable = lib.mkEnableOption "CLI meta-profile (base tools)";
  gui.enable = lib.mkEnableOption "GUI meta-profile (desktop environment)";
  restic.enable = lib.mkEnableOption "Restic backup service (user level)";
  signing.enable = lib.mkEnableOption "commit-signing key (user level)";
}
