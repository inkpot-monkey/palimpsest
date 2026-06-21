# The host's desktop binding for the contract's gui-session decision (ADR-0021 review).
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

    # The display backend rendering the session-union decision. Set ONCE so any number
    # of gui users share it instead of each imposing a (conflicting) display server.
    services = {
      displayManager.sddm.enable = lib.mkDefault true;
      displayManager.defaultSession = lib.mkDefault "plasma";
      desktopManager.plasma6.enable = lib.mkDefault true;
      # Offer X11 iff some granted gui user wants it.
      xserver.enable = lib.mkDefault surface.x11;
      # plasma6 defaults the Wayland greeter on (mkDefault true). Keep that when the
      # union includes a Wayland user; override it off (above mkDefault, below a host
      # mkForce) when the union is X11-only — two mkDefaults of differing values would
      # conflict, hence the explicit priority (ADR-0019).
      displayManager.sddm.wayland.enable = lib.mkIf (!surface.wayland) (lib.mkOverride 900 false);
    };
  };
}
