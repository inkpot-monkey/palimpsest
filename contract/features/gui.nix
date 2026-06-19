# Contract-owned `gui` feature module — the host effects of the gui grant that are
# neither the account itself (the realization, ADR-0015 mechanic 5) nor the display
# surface (the realization's gui-session union, ADR-0016). Applied fleet-wide and
# gated on *any* gui grant, so a user's home-manager config never writes these — the
# contract does, on the host's behalf, only where gui is granted (ADR-0018: a feature
# module is the only thing that writes host config on a user's behalf).
#
# Prototype scope (slice 10): uinput + the emacs overlay (packages ride features,
# ADR-0015 mechanic 4). The desktop hardware groups ride the gui grant via
# contract.featureGroups.gui (the realization confers them, clamped). Still in the
# user module pending slice 11: kanata + xkb (host keyboard config) and the
# electron permittedInsecurePackages concession (nixpkgs.config does not merge cleanly).
{
  lib,
  config,
  inputs,
  ...
}:
let
  anyGuiGranted = lib.any (u: u.granted.gui.enable or false) (lib.attrValues config.custom.users);
in
{
  config = lib.mkIf anyGuiGranted {
    # Desktop input tooling (kanata and friends) needs the uinput device.
    hardware.uinput.enable = true;
    # The emacs feature rides the gui grant: its overlay is applied ONLY where gui is
    # granted, never fleet-wide.
    nixpkgs.overlays = [ inputs.emacs-overlay.overlays.default ];
  };
}
