# The contract's OWN conformance suite (ADR-0020 Q5): proves the contract's promises in
# ISOLATION — synthetic manifests bound on synthetic systems built from the contract
# umbrella + bare nixpkgs, with no host repo, no real user, and no host bindings. This is
# what gives the contract independent CI and protects it for every consumer.
#
# Because the display *backend* is a host binding (the contract only decides), this suite
# asserts the session-union DECISION (custom.gui.surface), not SDDM/Plasma. The rendering
# test (the gui-union VM) and the real-fleet coherence gate stay in the host repo.
{
  lib,
  pkgs,
  contractModule,
  contractLib,
  safeSet,
  featureGroups,
  privilegedGroups,
  nixosSystem,
  system,
}:
let
  # A minimal bootable system built from ONLY the contract umbrella + bare nixpkgs.
  base =
    mods:
    nixosSystem {
      modules = [
        contractModule
        {
          nixpkgs.hostPlatform = system;
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "tmpfs";
            fsType = "tmpfs";
          };
          system.stateVersion = "25.11";
          # Stub the platform interface (ADR-0020 review F3). The contract's own CI binds
          # no real secrets backend; a no-op keeps the suite robust if a future system-side
          # secret feature reads custom.platform.secretFile during eval.
          custom.platform = {
            secretFile = _: builtins.toFile "stub-secret" "";
            secretPath = _: builtins.toFile "stub-secret" "";
          };
        }
      ]
      ++ mods;
    };
  eval = mods: (base mods).config;

  # A synthetic manifest — pure data, exactly as a real one: identity + (for gui) a
  # session preference, no grants (the host grants), no system config.
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
  grant = name: features: { custom.users.${name}.granted = features; };

  # --- grant / deny ---
  granted = eval [
    (mkUser "alice" { })
    (grant "alice" { gui.enable = true; })
  ];
  denied = eval [ (mkUser "alice" { }) ];

  # --- the gui-session union DECISION (the contract's output, not a display backend) ---
  waylandOnly = eval [
    (mkUser "alice" { session = "wayland"; })
    (grant "alice" { gui.enable = true; })
  ];
  x11Only = eval [
    (mkUser "bob" { session = "x11"; })
    (grant "bob" { gui.enable = true; })
  ];
  bothSessions = eval [
    (mkUser "alice" { session = "wayland"; })
    (mkUser "bob" { session = "x11"; })
    (grant "alice" { gui.enable = true; })
    (grant "bob" { gui.enable = true; })
  ];

  # --- the privileged-group clamp ---
  clampNoGrant = eval [
    (mkUser "alice" { })
    {
      custom.users.alice.identity.extraGroups = [
        "docker"
        "audio"
      ];
    }
  ];
  clampWithGrant = eval [
    (mkUser "alice" { })
    (grant "alice" { workstation.enable = true; })
    { custom.users.alice.identity.extraGroups = [ "docker" ]; }
  ];
  groupsOf = c: c.users.users.alice.extraGroups;

  # --- the exposed-host ban ---
  failing = c: builtins.filter (a: !a.assertion) c.assertions;
  exposedRestic = eval [
    (mkUser "alice" { })
    (grant "alice" { restic.enable = true; })
    {
      custom.host.exposed = true;
      networking.hostName = "agent";
    }
  ];
  normalRestic = eval [
    (mkUser "alice" { })
    (grant "alice" { restic.enable = true; })
    { networking.hostName = "box"; }
  ];

  # --- recipients-from-grants ---
  granterSys = base [
    (mkUser "alice" { })
    (grant "alice" { restic.enable = true; })
  ];
  abstainerSys = base [ (mkUser "alice" { }) ];
  recipients = contractLib.mkFeatureRecipients {
    granter = granterSys;
    abstainer = abstainerSys;
  };

  # --- the matrix: synthetic users × host archetypes ---
  users = {
    alice = mkUser "alice" { session = "wayland"; };
    bob = mkUser "bob" { session = "x11"; };
    carol = mkUser "carol" { gui = false; };
  };
  userNames = [
    "alice"
    "bob"
    "carol"
  ];
  allUsers = lib.attrValues users;
  mkArchetype =
    { exposed, grantsFor }:
    base (
      [
        { custom.users = lib.mkMerge (map (u: u.custom.users) allUsers); }
        {
          custom.host.exposed = exposed;
          networking.hostName = "arch";
        }
      ]
      ++ map (n: grant n (grantsFor n)) userNames
    );
  workstationArch = mkArchetype {
    exposed = false;
    grantsFor =
      n:
      if users.${n}.custom.users.${n}.identity.profile == "gui" then
        {
          gui.enable = true;
          workstation.enable = true;
        }
      else
        { workstation.enable = true; };
  };
  agentArch = mkArchetype {
    exposed = true;
    grantsFor = _: { workstation.enable = true; };
  };
  headlessArch = mkArchetype {
    exposed = false;
    grantsFor = _: { };
  };
  accountsRealized = sys: lib.all (n: sys.config.users.users.${n}.isNormalUser or false) userNames;
  archetypes = [
    workstationArch
    agentArch
    headlessArch
  ];

  assertions = [
    {
      name = "grant: gui confers uinput";
      ok = granted.hardware.uinput.enable;
    }
    {
      name = "deny: no grant leaves uinput off";
      ok = !denied.hardware.uinput.enable;
    }
    {
      name = "grant: the gui surface decision is enabled";
      ok = granted.custom.gui.surface.enabled;
    }
    {
      name = "deny: the gui surface decision is off";
      ok = !denied.custom.gui.surface.enabled;
    }
    {
      name = "union: a wayland user ⇒ surface offers wayland, not x11";
      ok = waylandOnly.custom.gui.surface.wayland && !waylandOnly.custom.gui.surface.x11;
    }
    {
      name = "union: an x11 user ⇒ surface offers x11, not wayland";
      ok = x11Only.custom.gui.surface.x11 && !x11Only.custom.gui.surface.wayland;
    }
    {
      name = "union: wayland + x11 users ⇒ surface offers both";
      ok = bothSessions.custom.gui.surface.wayland && bothSessions.custom.gui.surface.x11;
    }
    {
      name = "clamp: a privileged group in identity is dropped without a grant";
      ok = !(lib.elem "docker" (groupsOf clampNoGrant));
    }
    {
      name = "clamp: a non-privileged declared group passes through";
      ok = lib.elem "audio" (groupsOf clampNoGrant);
    }
    {
      name = "grant: the workstation grant confers the privileged group";
      ok = lib.elem "docker" (groupsOf clampWithGrant);
    }
    {
      name = "exposed host granting a secret-bearing feature fails an assertion";
      ok = lib.any (a: lib.hasInfix "restic" a.message) (failing exposedRestic);
    }
    {
      name = "non-exposed host granting the same feature raises no exposed-host failure";
      ok = !(lib.any (a: lib.hasInfix "exposed host" a.message) (failing normalRestic));
    }
    {
      name = "safe set: gui is runtime-eligible";
      ok = lib.elem "gui" safeSet;
    }
    {
      name = "safe set: privileged + secret-bearing features are excluded";
      ok =
        !(lib.elem "workstation" safeSet)
        && !(lib.elem "virtualization" safeSet)
        && !(lib.elem "restic" safeSet)
        && !(lib.elem "signing" safeSet);
    }
    {
      name = "gui confers no privileged group";
      ok = !(lib.any (g: lib.elem g privilegedGroups) featureGroups.gui);
    }
    {
      name = "virtualization confers privileged groups (only via its grant)";
      ok = lib.elem "libvirtd" featureGroups.virtualization;
    }
    {
      name = "recipients: only the granting host is a recipient";
      ok = (recipients."profiles/restic.yaml" or [ ]) == [ "granter" ];
    }
    {
      name = "matrix: every user realizes on every archetype, no failing assertion";
      ok = lib.all (sys: (accountsRealized sys) && (failing sys.config == [ ])) archetypes;
    }
    {
      name = "matrix: the workstation archetype offers both sessions (alice wayland + bob x11)";
      ok =
        workstationArch.config.custom.gui.surface.wayland && workstationArch.config.custom.gui.surface.x11;
    }
    {
      name = "matrix: the headless archetype needs no display surface";
      ok = !headlessArch.config.custom.gui.surface.enabled;
    }
    {
      name = "matrix: the exposed agent grants no gui yet realizes all users";
      ok = (!agentArch.config.custom.gui.surface.enabled) && (accountsRealized agentArch);
    }
  ];
  failures = builtins.filter (a: !a.ok) assertions;
  report = lib.concatMapStringsSep "\n" (
    a: "  ${if a.ok then "ok  " else "FAIL"}  ${a.name}"
  ) assertions;
in
pkgs.runCommand "contract-conformance" { } ''
  cat <<'EOF'
  contract conformance — synthetic users × the contract umbrella (no host repo):
  ${report}
  EOF
  ${lib.optionalString (failures != [ ]) ''
    echo "contract conformance FAILED (see above)" >&2
    exit 1
  ''}
  touch $out
''
