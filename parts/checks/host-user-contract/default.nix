# Regression gate for the host↔user contract (ADR-0015, slice 08).
#
# Proves the gui *grant* drives the gui feature and that *deny* (no grant) is a
# true no-op. Both configs use the inkpotmonkey **cli** variant — so
# `identity.profile` is "cli" in both and the only difference is
# `granted.gui.enable`. That isolates the grant from the legacy
# `identity.profile == "gui"` proxy: the gui system effects below come purely
# from the grant.
#
# This is an eval-level check (it inspects real nixosSystem evaluations built via
# self.lib.mkSystem, exactly as hosts are). It verifies the grant *logic* without
# booting a desktop. Slice 03 adds the platform-resolver and exposed-host
# assertions below. Runtime, VM-boot assertions (a feature secret present at /run
# on a granting host) need a booted machine and arrive with a later slice.
{ self, pkgs, ... }:
let
  inherit (pkgs) lib;

  evalHost =
    grantsModule:
    (self.lib.mkSystem {
      modules = [
        self.nixosProfiles.bundle
        self.users.inkpotmonkey.cli
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
    }).config;

  granted = evalHost { custom.users.inkpotmonkey.granted.gui.enable = true; };
  denied = evalHost { };

  # Slice 03 — the exposed-host assertion. restic is secret-bearing (contract
  # featureMeta), so an exposed host granting it must raise a failing assertion;
  # a normal host granting the same feature must not.
  exposedRestic = evalHost {
    custom.host.exposed = true;
    custom.users.inkpotmonkey.granted.restic.enable = true;
  };
  normalRestic = evalHost {
    custom.users.inkpotmonkey.granted.restic.enable = true;
  };
  failing = cfg: builtins.filter (a: !a.assertion) cfg.assertions;

  assertions = [
    {
      name = "granted enables the display manager";
      ok = granted.services.displayManager.sddm.enable;
    }
    {
      name = "granted enables kanata";
      ok = granted.services.kanata.enable;
    }
    {
      name = "granted enables uinput";
      ok = granted.hardware.uinput.enable;
    }
    {
      name = "denied leaves the display manager off";
      ok = !denied.services.displayManager.sddm.enable;
    }
    {
      name = "denied leaves kanata off";
      ok = !denied.services.kanata.enable;
    }
    {
      name = "denied leaves uinput off";
      ok = !denied.hardware.uinput.enable;
    }
    {
      name = "system platform resolves a secret source to an existing file";
      ok = builtins.pathExists (denied.custom.platform.secretFile "restic");
    }
    {
      name = "exposed host granting a secret-bearing feature fails an assertion";
      ok = lib.any (a: lib.hasInfix "restic" a.message) (failing exposedRestic);
    }
    {
      name = "non-exposed host granting the same feature raises no exposed-host failure";
      ok = !(lib.any (a: lib.hasInfix "exposed host" a.message) (failing normalRestic));
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
