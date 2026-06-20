# Contract-owned `gui` feature module — the host effects of the gui grant that are
# neither the account itself (the realization, ADR-0015 mechanic 5) nor the display
# surface (the realization's gui-session union, ADR-0019). Applied fleet-wide and
# gated on *any* gui grant, so a user's home-manager config never writes these — the
# contract does, on the host's behalf, only where gui is granted (ADR-0018: a feature
# module is the only thing that writes host config on a user's behalf).
#
# Scope: uinput + the emacs overlay (packages ride features, ADR-0015 mechanic 4) +
# the host keyboard layout + the electron permit for the gui desktop apps. The desktop
# hardware groups ride the gui grant via contract.featureGroups.gui (the realization
# confers them, clamped); the display surface (sddm/plasma6/xserver) is the
# realization's session union (ADR-0019). kanata stays host-side (an executable
# payload, not a safe-set feature — slice 11; portable kanata is issue 18).
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
    # Host keyboard layout for the gui seat (used by Wayland compositors too). A host
    # or another gui user may override it; the fleet default is gb.
    services.xserver.xkb = {
      layout = lib.mkDefault "gb";
      variant = lib.mkDefault "";
    };
    # A gui app (Claude Desktop) pulls electron. Contributed through the contract's
    # insecure-packages aggregator so it merges with any host's own permits instead of
    # being clobbered by them (contract/insecure-packages.nix).
    custom.insecurePackages = [ "electron-39.8.10" ];
  };
}
