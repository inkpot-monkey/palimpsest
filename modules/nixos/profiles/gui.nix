# Everything the fleet needs to present a graphical seat, in one place.
#
# This file carries TWO INDEPENDENT GATES, and they are deliberately not collapsed into
# one — they answer different questions and do not always agree:
#
#   1. `custom.profiles.gui.enable` — the HOST's opt-in for generic desktop plumbing
#      (input devices, polkit, power). Set per host in hosts/<name>/configuration.nix.
#
#   2. `contract.display.enabled` — the CONTRACT's decision that a shared display
#      surface must exist at all (contract ADR-0021). Nothing here sets it — it is `readOnly`,
#      derived from the session shapes the MACHINE declared it can run (`contract.modes`). That
#      is why this module is imported fleet-wide from profiles/base.nix and self-gates: it must
#      fire on exactly the hosts the contract says need a seat, whether or not (1) is also set.
#
# Merging the two former files (gui-base.nix + gui-desktop.nix) removed the split without
# merging the conditions: block (2) below is still the host's *binding* for the contract's
# decision, and swapping it for a gdm/gnome one changes the desktop without touching the
# contract. The contract stays display-server-agnostic (contract ADR-0021).
{
  config,
  lib,
  ...
}:

let
  cfg = config.custom.profiles.gui;
  surface = config.contract.display;
in
{
  options.custom.profiles.gui = {
    enable = lib.mkEnableOption "GUI configuration (polkit, libinput, upower)";
  };

  config = lib.mkMerge [
    # ── (1) Host opt-in: generic desktop plumbing ────────────────────────────────
    (lib.mkIf cfg.enable {
      # Input Devices (Touchpad)
      services.libinput.enable = true;

      # Security
      security.polkit.enable = true;

      # Services
      services.upower.enable = true;

      # NOTE: no gnome-keyring here. Plasma's own ksecretd already owns
      # `org.freedesktop.secrets` on this seat, so enabling gnome-keyring alongside it
      # installed a second Secret Service implementation that lost the name race on every
      # login, left a dead `gnome-keyring-daemon --components=secrets` running, and made
      # display-manager log `gkr-pam: unable to locate daemon control file`. The live store
      # is kwallet (~/.local/share/kwalletd); the gnome-keyring files were stale and
      # effectively empty. If a GNOME seat is ever added, enable it in THAT binding, not here.
    })

    # ── (2) Contract binding: the display surface itself ─────────────────────────
    (lib.mkIf surface.enabled {
      # Networking for an interactive desktop host (host policy, finding 1) — this was
      # previously bundled into the contract's gui grant, which made it contract logic; it
      # is host policy and belongs on this side of the seam.
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
    })
  ];
}
