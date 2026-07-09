{ ... }:
{
  imports = [ ./bundle.nix ];
  # eyeofalligator logs into an X11 session — this is feature *configuration*
  # (user-owned), unioned with other gui users' sessions by the realization (contract ADR-0003).
  # The gui *grant* is host-owned: weedySeadragon grants it in the fleet grant matrix
  # (hosts/default.nix). The user never self-grants (contract ADR-0002, slice 16).
  custom.users.eyeofalligator.gui.session = "x11";
}
