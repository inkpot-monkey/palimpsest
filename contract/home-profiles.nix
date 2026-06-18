# Home meta-profile options — part of the host↔user contract (ADR-0015).
# Consumed by modules/homeManager/options.nix to declare `custom.home.profiles.*`.
{ lib }:
{
  cli.enable = lib.mkEnableOption "CLI meta-profile (base tools)";
  gui.enable = lib.mkEnableOption "GUI meta-profile (desktop environment)";
}
