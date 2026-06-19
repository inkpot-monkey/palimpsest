# The conformance MATRIX (ADR-0018, slice 16): the literal proof of the contract's
# promise — *any* host can enable *any* user. It crosses a set of synthetic user
# manifests against a set of host **archetypes** (the contract-relevant trait-tuples a
# real host can have) and asserts every pairing realizes a valid system with the
# invariants intact: every account materializes, no host assertion fails, the gui
# union offers every granted session, and the exposed-host ban holds.
#
# This is an eval check (it builds real nixosSystem evaluations via mkSystem, exactly
# as hosts do). It complements ../host-user-contract (which probes one host deeply) by
# proving breadth across the cross-product. Coherence: every real host's trait-tuple
# (its `exposed` flag) is covered by an archetype here, so "passes the matrix" implies
# the real fleet's pairings are sound.
{ self, pkgs, ... }:
let
  inherit (pkgs) lib;

  # Synthetic user manifests — identity + (for gui users) a session preference. Pure
  # data, exactly as a real manifest: no grants (the host grants), no system config.
  mkUser =
    name:
    {
      gui ? true,
      session ? "wayland",
    }:
    {
      custom.users.${name} = {
        identity = {
          name = "User ${name}";
          email = "${name}@example.invalid";
          username = name;
          profile = if gui then "gui" else "cli";
        };
      }
      // lib.optionalAttrs gui { gui.session = session; };
    };

  users = {
    alice = mkUser "alice" {
      gui = true;
      session = "wayland";
    };
    bob = mkUser "bob" {
      gui = true;
      session = "x11";
    };
    carol = mkUser "carol" { gui = false; };
  };
  userNames = lib.attrNames users;
  allUserModules = lib.attrValues users;

  # A minimal but real bootable host, parameterized by the archetype's traits and the
  # grants it makes. Builds via mkSystem, like every host.
  mkArchetype =
    {
      exposed,
      grantsFor,
    }:
    self.lib.mkSystem {
      modules = [
        self.nixosProfiles.bundle
        {
          custom.profiles.base.enable = true;
          custom.host.exposed = exposed;
          nixpkgs.hostPlatform = "x86_64-linux";
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "tmpfs";
            fsType = "tmpfs";
          };
          system.stateVersion = "25.11";
        }
        # Every user manifest is bound on every archetype (the cross-product).
        { custom.users = lib.mkMerge (map (u: u.custom.users) allUserModules); }
        # The archetype grants each user per its policy.
        {
          custom.users = lib.mapAttrs (name: _: {
            granted = grantsFor name;
          }) users;
        }
      ];
    };

  # The archetypes span the contract-relevant trait-tuples a real host can have.
  archetypes = {
    # A workstation: not exposed, grants gui (+ workstation) to gui users.
    workstation = mkArchetype {
      exposed = false;
      grantsFor =
        name:
        if (users.${name}.custom.users.${name}.identity.profile == "gui") then
          {
            gui.enable = true;
            workstation.enable = true;
          }
        else
          { workstation.enable = true; };
    };
    # An exposed agent box: grants only non-secret workstation, never gui/secrets.
    agent = mkArchetype {
      exposed = true;
      grantsFor = _: { workstation.enable = true; };
    };
    # A headless server: grants nothing — every user is still a valid (login) account.
    headless = mkArchetype {
      exposed = false;
      grantsFor = _: { };
    };
  };

  # An exposed archetype that (mis)grants a secret-bearing feature must FAIL its
  # assertions — the exposed-host ban. Built separately as a negative fixture.
  exposedRestic = mkArchetype {
    exposed = true;
    grantsFor =
      name:
      {
        workstation.enable = true;
      }
      // lib.optionalAttrs (name == "alice") { restic.enable = true; };
  };

  failing = sys: builtins.filter (a: !a.assertion) sys.config.assertions;
  accountsRealized =
    sys: lib.all (name: sys.config.users.users.${name}.isNormalUser or false) userNames;

  # Every (user × archetype) pairing: the account realizes and no host assertion fails.
  matrixOk = lib.all (sys: (accountsRealized sys) && (failing sys == [ ])) (
    lib.attrValues archetypes
  );

  assertions = [
    {
      name = "matrix: every user realizes on every archetype, with no failing assertion";
      ok = matrixOk;
    }
    {
      name = "matrix: the workstation archetype offers BOTH sessions (alice wayland + bob x11)";
      ok =
        archetypes.workstation.config.services.displayManager.sddm.wayland.enable
        && archetypes.workstation.config.services.xserver.enable;
    }
    {
      name = "matrix: the headless archetype has no display manager (no gui granted)";
      ok = !archetypes.headless.config.services.displayManager.sddm.enable;
    }
    {
      name = "matrix: the exposed agent grants no gui (workstation only) yet realizes all users";
      ok =
        (!archetypes.agent.config.services.displayManager.sddm.enable)
        && (accountsRealized archetypes.agent);
    }
    {
      name = "matrix: an exposed host granting a secret-bearing feature fails the ban";
      ok = lib.any (a: lib.hasInfix "exposed host" a.message) (failing exposedRestic);
    }
    {
      name = "coherence: every real host's exposed-trait is covered by an archetype";
      ok =
        let
          realExposed = lib.unique (
            map (h: h.config.custom.host.exposed) (lib.attrValues self.nixosConfigurations)
          );
          archetypeExposed = lib.unique (map (a: a.config.custom.host.exposed) (lib.attrValues archetypes));
        in
        lib.all (e: lib.elem e archetypeExposed) realExposed;
    }
  ];

  failures = builtins.filter (a: !a.ok) assertions;
  report = lib.concatMapStringsSep "\n" (
    a: "  ${if a.ok then "ok  " else "FAIL"}  ${a.name}"
  ) assertions;
in
pkgs.runCommand "host-user-contract-matrix-test" { } ''
  cat <<'EOF'
  host↔user contract — conformance matrix (users × host archetypes):
  ${report}
  EOF
  ${lib.optionalString (failures != [ ]) ''
    echo "host↔user contract MATRIX test FAILED (see above)" >&2
    exit 1
  ''}
  touch $out
''
