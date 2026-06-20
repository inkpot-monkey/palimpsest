# Feature *configuration* — the user-owned parameters of a feature, as opposed to
# the host-owned *grant* (contract/features.nix). The realization reads these only
# for a granted feature (ADR-0015 mechanic 5, ADR-0019). Host-affecting parameters
# AGGREGATE across all granted users rather than conflict; user-scoped ones apply
# per user. Returns an options fragment merged into the `custom.users.<u>` submodule
# (so a user writes `custom.users.<u>.gui.session`, never a raw host singleton).
{ lib }:
{
  # gui.session: which display session this user logs into. Host-affecting and
  # UNION-aggregated (ADR-0019): on a single-seat host the display surface is the
  # union of every granted gui user's session, so a Wayland user and an X11 user
  # coexist — each logs into their own. A user declares this; it NEVER sets
  # services.xserver.enable directly (the realization derives that from the union).
  gui.session = lib.mkOption {
    type = lib.types.enum [
      "wayland"
      "x11"
    ];
    default = "wayland";
    description = "Display session this user logs into; unioned across granted gui users by the realization.";
  };
}
