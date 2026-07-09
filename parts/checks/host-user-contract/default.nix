# Regression gate for the host↔user contract (its ADR-0001, slice 08).
#
# Proves the gui *grant* drives the gui feature and that *deny* (no grant) is a
# true no-op. Both configs bind the SAME inkpotmonkey manifest; the only difference is
# `granted.gui.enable`, so the gui system effects below come purely from the grant —
# nothing about the user changes between them.
#
# This is an eval-level check (it inspects real nixosSystem evaluations built via
# self.lib.mkSystem, exactly as hosts are). It verifies the grant *logic* without
# booting a desktop. Slice 03 adds the platform-resolver and exposed-host
# assertions below. Runtime, VM-boot assertions (a feature secret present at /run
# on a granting host) need a booted machine and arrive with a later slice.
{ self, pkgs, ... }:
let
  inherit (pkgs) lib;

  evalSystem =
    grantsModule:
    self.lib.mkSystem {
      modules = [
        self.nixosProfiles.bundle
        # The user is bound as a non-granting manifest (contract ADR-0002, slice 16); each test
        # supplies the grants it needs via grantsModule, never a self-granting variant.
        self.users.inkpotmonkey.manifest
        {
          custom.profiles.base.enable = true;
          nixpkgs.hostPlatform = "x86_64-linux";
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "tmpfs";
            fsType = "tmpfs";
          };
          system.stateVersion = "25.11";
        }
        grantsModule
      ];
    };
  evalHost = grantsModule: (evalSystem grantsModule).config;

  # Keep the system handles for granted/denied so the package assertions can read
  # the overlaid `pkgs` (which lives at the system level, not under config).
  grantedSys = evalSystem { custom.users.inkpotmonkey.granted.gui.enable = true; };
  deniedSys = evalSystem { };
  granted = grantedSys.config;
  denied = deniedSys.config;

  # contract ADR-0003 — the gui-session union. `grantedSys` above has a single gui user whose
  # session defaults to Wayland: the host enables the Wayland greeter and NOT X11.
  # A host whose only gui user wants X11 enables X11 and not the Wayland greeter.
  x11OnlySys = evalSystem {
    custom.users.inkpotmonkey.granted.gui.enable = true;
    custom.users.inkpotmonkey.gui.session = "x11";
  };
  x11Only = x11OnlySys.config;

  # Two granted gui users with *different* sessions on one (single-seat) host: the
  # host must offer BOTH session types and realize BOTH accounts. This is the
  # weedySeadragon coexistence case as a synthetic fixture.
  twoSessionSys = evalSystem {
    custom.users.inkpotmonkey.granted.gui.enable = true;
    custom.users.inkpotmonkey.gui.session = "wayland";
    custom.users.gamma = {
      identity = {
        name = "Gamma";
        email = "gamma@example.invalid";
        username = "gamma";
      };
      granted.gui.enable = true;
      gui.session = "x11";
    };
  };
  twoSession = twoSessionSys.config;

  # Slice 03 — the exposed-host assertion. signing is secret-bearing (contract
  # featureMeta), so an exposed host granting it must raise a failing assertion;
  # a normal host granting the same feature must not.
  exposedSigning = evalHost {
    custom.host.exposed = true;
    custom.users.inkpotmonkey.granted.signing.enable = true;
  };
  normalSigning = evalHost {
    custom.users.inkpotmonkey.granted.signing.enable = true;
  };
  failing = cfg: builtins.filter (a: !a.assertion) cfg.assertions;

  # Slice 04 — the privileged-group clamp. A privileged group named in a user's
  # own identity is untrusted: it is dropped unless a grant confers it.
  # The manifest base grants nothing, so "no grant" is just the absence of a grant.
  clampNoGrant = evalHost {
    custom.users.inkpotmonkey.identity.extraGroups = lib.mkForce [
      "docker"
      "audio"
    ];
  };
  clampWithGrant = evalHost {
    custom.users.inkpotmonkey.granted.workstation.enable = true;
    custom.users.inkpotmonkey.identity.extraGroups = lib.mkForce [ "docker" ];
  };
  groupsOf = cfg: cfg.users.users.inkpotmonkey.extraGroups;

  assertions = [
    {
      name = "granted enables the display manager";
      ok = granted.services.displayManager.sddm.enable;
    }
    {
      name = "granted enables uinput (via the contract gui feature module)";
      ok = granted.hardware.uinput.enable;
    }
    {
      name = "denied leaves the display manager off";
      ok = !denied.services.displayManager.sddm.enable;
    }
    {
      name = "denied leaves uinput off";
      ok = !denied.hardware.uinput.enable;
    }
    # NOTE: the pure-contract-logic assertions (group policy, the derived safe set,
    # recipients-from-grants) moved to the contract flake's own conformance suite
    # (inputs.contract.checks.<system>.conformance, contract ADR-0004 Q5). What remains here is
    # INTEGRATION: the host bindings (display rendering, the emacs glue, the platform
    # resolver) realizing the contract as wired into THIS fleet, on the real manifest.
    {
      name = "system platform resolves a secret source to an existing file";
      ok = builtins.pathExists (denied.custom.platform.secretFile "example");
    }
    {
      name = "exposed host granting a secret-bearing feature fails an assertion";
      ok = lib.any (a: lib.hasInfix "signing" a.message) (failing exposedSigning);
    }
    {
      name = "non-exposed host granting the same feature raises no exposed-host failure";
      ok = !(lib.any (a: lib.hasInfix "exposed host" a.message) (failing normalSigning));
    }
    {
      name = "clamp: a privileged group declared in identity is dropped without a grant";
      ok = !(lib.elem "docker" (groupsOf clampNoGrant));
    }
    {
      name = "clamp: a non-privileged declared group still passes through";
      ok = lib.elem "audio" (groupsOf clampNoGrant);
    }
    {
      name = "grant: the workstation grant confers the privileged group";
      ok = lib.elem "docker" (groupsOf clampWithGrant);
    }
    {
      name = "packages ride the feature: granting gui applies the emacs overlay";
      ok = grantedSys.pkgs ? emacs-unstable;
    }
    {
      name = "denying gui keeps the emacs overlay out";
      ok = !(deniedSys.pkgs ? emacs-unstable);
    }
    {
      name = "union: a Wayland-only gui host enables the Wayland greeter";
      ok = grantedSys.config.services.displayManager.sddm.wayland.enable;
    }
    {
      name = "union: a Wayland-only gui host does not enable X11";
      ok = !grantedSys.config.services.xserver.enable;
    }
    {
      name = "union: an X11-only gui host enables X11";
      ok = x11Only.services.xserver.enable;
    }
    {
      name = "union: an X11-only gui host does not enable the Wayland greeter";
      ok = !x11Only.services.displayManager.sddm.wayland.enable;
    }
    {
      name = "union: two gui users with different sessions ⇒ host offers both (Wayland)";
      ok = twoSession.services.displayManager.sddm.wayland.enable;
    }
    {
      name = "union: two gui users with different sessions ⇒ host offers both (X11)";
      ok = twoSession.services.xserver.enable;
    }
    {
      name = "union: both gui users are realized as accounts";
      ok = (twoSession.users.users ? inkpotmonkey) && (twoSession.users.users ? gamma);
    }
  ];

  failures = builtins.filter (a: !a.ok) assertions;
  report = lib.concatMapStringsSep "\n" (
    a: "  ${if a.ok then "ok  " else "FAIL"}  ${a.name}"
  ) assertions;
in
pkgs.runCommand "host-user-contract-grant-test" { } ''
  cat <<'EOF'
  host↔user contract — gui grant/deny assertions:
  ${report}
  EOF
  ${lib.optionalString (failures != [ ]) ''
    echo "host↔user contract test FAILED (see above)" >&2
    exit 1
  ''}
  touch $out
''
