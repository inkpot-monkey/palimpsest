{ ... }:
{
  imports = [ ./bundle.nix ];
  # eyeofalligator is a gui user: grant gui so the shared display infrastructure
  # is conferred even on a host where it is the only user (ADR-0015).
  custom.users.eyeofalligator.granted.gui.enable = true;
}
