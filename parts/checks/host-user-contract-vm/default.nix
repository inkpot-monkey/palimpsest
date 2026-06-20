# Runtime VM smoke for the gui-session union (ADR-0019) — the one piece of the
# contract's regression gate that genuinely needs a booted machine rather than a
# pure eval (the eval-level flags live in ../host-user-contract).
#
# It boots ONE single-seat host that grants gui to two users with *different*
# `gui.session` preferences (Wayland + X11) and proves the realization derived a
# display surface offering BOTH sessions: the live system's session directory
# contains a plasma Wayland session AND a plasma X11 session, and both user
# accounts activated. That is the coexistence claim — two users log into their own
# session on one seat — observed on a real machine, not just in the option tree.
#
# Lean by design: the display-manager unit is present but not pulled in at boot
# (we only assert the assembled session *artifacts* + account activation), so the
# VM reaches multi-user without starting a graphical greeter.
{
  self,
  pkgs,
  ...
}:
# Uses the modern `runNixOSTest` framework (not legacy `nixosTest`) because we need
# `node.specialArgs` to thread the repo's `self` into the node — an `imports` line
# in users/identity.nix references it before config is evaluated, so it cannot come
# via a config-level `_module.args`.
pkgs.testers.runNixOSTest {
  name = "host-user-contract-gui-union-test";

  node.specialArgs = { inherit self; };

  nodes.machine =
    { lib, ... }:
    {
      imports = [
        # Brings the `custom.users` schema + the host-invariant realization that
        # derives the display surface from granted users' sessions.
        ../../../users/identity.nix
      ];

      config = {
        system.stateVersion = "25.11";

        # Keep the boot lean: the greeter need not run for the session files to be
        # assembled into the system (they come from the session packages, not the
        # DM unit). Mirrors the jmap check's wantedBy trick.
        systemd.services.display-manager.wantedBy = lib.mkForce [ ];

        # Two gui users on one seat, each wanting a different session. The host
        # grants gui to both; the realization unions their sessions (ADR-0019).
        custom.users.aurelia = {
          identity = {
            name = "Aurelia Wayland";
            email = "aurelia@example.invalid";
            username = "aurelia";
            profile = "gui";
          };
          granted.gui.enable = true;
          gui.session = "wayland";
        };
        custom.users.borealis = {
          identity = {
            name = "Borealis X11";
            email = "borealis@example.invalid";
            username = "borealis";
            profile = "gui";
          };
          granted.gui.enable = true;
          gui.session = "x11";
        };
      };
    };

  # `nodes` lets us interpolate the *derived* session directory the live system was
  # built with, then assert against it inside the booted VM.
  testScript =
    { nodes, ... }:
    let
      sessions = nodes.machine.services.displayManager.sessionData.desktops;
    in
    ''
      machine.start()
      machine.wait_for_unit("multi-user.target")

      # The union artifact: the host offers BOTH a Wayland and an X11 plasma
      # session. Each granted gui user logs into their own on this single seat.
      machine.succeed("ls ${sessions}/share/wayland-sessions/ | grep -qi plasma")
      machine.succeed("ls ${sessions}/share/xsessions/ | grep -qi plasma")

      # Both gui users are realized as real accounts on the booted host.
      machine.succeed("getent passwd aurelia")
      machine.succeed("getent passwd borealis")

      print(machine.succeed("ls ${sessions}/share/wayland-sessions/ ${sessions}/share/xsessions/"))
    '';
}
