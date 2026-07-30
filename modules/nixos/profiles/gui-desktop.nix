# The host's desktop binding for the contract's gui-session decision (contract ADR-0005 review).
# The contract (contract/realization.nix) decides which sessions the shared display
# surface must offer — `custom.gui.surface = { enabled, wayland, x11 }` — and this
# module RENDERS that decision with a concrete display backend: SDDM + Plasma 6.
#
# This is the host's choice, deliberately NOT in the contract: a GNOME host swaps this
# module for a gdm/gnome one, and the contract's decision is unchanged. It also carries
# the interactive-desktop networking policy (NetworkManager), which was previously
# bundled into the contract's gui grant — host policy, not contract (finding 1).
#
# Imported fleet-wide alongside the contract in profiles/base.nix and self-gated on the
# decision, so it fires on exactly the hosts the contract's gui realization used to.
{
  config,
  lib,
  ...
}:
let
  surface = config.custom.gui.surface;
in
{
  config = lib.mkIf surface.enabled {
    # Networking for an interactive desktop host (host policy, finding 1).
    networking.networkmanager.enable = true;

    # The uinput device (input injection for kanata & friends) and the host keyboard
    # layout — gui-seat host setup, not contract logic. Both used to sit in the contract
    # gui feature module; moved here so the contract carries no host/package specifics
    # (thermo-nuclear review). Fire on the same condition the contract feature used to.
    hardware.uinput.enable = true;

    # The display backend. Set ONCE so any number of gui users share it. This seat is WAYLAND:
    # the contract is display-server-agnostic (contract ADR-0021), so the host owns the session
    # type outright — the fleet runs wayland everywhere and never offers X11.
    services = {
      displayManager.sddm.enable = lib.mkDefault true;
      displayManager.sddm.wayland.enable = lib.mkDefault true;
      displayManager.defaultSession = lib.mkDefault "plasma";
      desktopManager.plasma6.enable = lib.mkDefault true;
      # X11 stays off (default). Host keyboard layout for the gui seat (used by Wayland too).
      xserver.xkb = {
        layout = lib.mkDefault "gb";
        variant = lib.mkDefault "";
      };
    };
  };
}
