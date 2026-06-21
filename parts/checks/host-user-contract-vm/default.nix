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
  inputs,
  ...
}:
# Uses the modern `runNixOSTest` framework (not legacy `nixosTest`) because we need
# `node.specialArgs` to thread the repo's `self` (and `inputs`, which the contract
# realization's gui feature module reads for the emacs overlay) into the node — an
# `imports` line in users/identity.nix references them before config is evaluated, so
# they cannot come via a config-level `_module.args`. Mirrors mkSystem's specialArgs.
pkgs.testers.runNixOSTest {
  name = "host-user-contract-gui-union-test";

  node.specialArgs = {
    inherit self inputs;
    inherit (self) settings;
  };

  # The contract gui feature module adds the emacs overlay via `nixpkgs.overlays`,
  # which the test driver's default read-only nixpkgs forbids. Let the node build its
  # own pkgs (as a real host does) so the granted-gui overlay applies cleanly.
  node.pkgsReadOnly = false;

  nodes.machine =
    { lib, ... }:
    {
      imports = [
        # Brings the `custom.users` schema + the host-invariant realization that
        # derives the gui-session *decision* (custom.gui.surface).
        ../../../users/identity.nix
        # The host display binding that renders that decision (SDDM + Plasma 6) — the
        # contract decides, the binding implements (ADR-0021 review). The VM asserts the
        # rendered plasma sessions, so it needs the binding, not just the decision.
        ../../../modules/nixos/profiles/gui-desktop.nix
      ];

      config = {
        system.stateVersion = "25.11";
        # Required once the node owns its nixpkgs (pkgsReadOnly = false above).
        nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;

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
