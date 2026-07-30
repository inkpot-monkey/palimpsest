{ ... }:
{
  imports = [ ./bundle.nix ];
  # eyeofalligator names the DESKTOP it logs into — "plasma" (ADR-0018: a user declares a desktop,
  # never a raw session type; the session type is DERIVED from the desktop by the seat). No host
  # maps it to x11, so it degrades to the wayland default — the fleet runs wayland everywhere now
  # (its old x11 preference was legacy). The gui *grant* stays host-owned (weedySeadragon grants it
  # in hosts/default.nix); the user never self-grants (contract ADR-0002, slice 16).
  custom.users.eyeofalligator.gui.desktop = "plasma";
}
