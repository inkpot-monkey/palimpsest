{ ... }:
{
  imports = [ ./bundle.nix ];
  # eyeofalligator is a gui user: grant gui so the shared display infrastructure
  # is conferred even on a host where it is the only user (ADR-0015).
  custom.users.eyeofalligator.granted.gui.enable = true;
  # eyeofalligator logs into an X11 session. This is feature configuration, not a
  # host singleton — the realization unions it with other gui users' sessions
  # (ADR-0016), so eyeofalligator's X11 and inkpotmonkey's Wayland coexist.
  custom.users.eyeofalligator.gui.session = "x11";
}
