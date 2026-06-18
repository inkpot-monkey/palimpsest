# Regression gate for the host↔user contract (ADR-0015, slice 08).
#
# Proves the gui *grant* drives the gui feature and that *deny* (no grant) is a
# true no-op. Both configs use the inkpotmonkey **cli** variant — so
# `identity.profile` is "cli" in both and the only difference is
# `granted.gui.enable`. That isolates the grant from the legacy
# `identity.profile == "gui"` proxy: the gui system effects below come purely
# from the grant.
#
# This is an eval-level check (it inspects two real nixosSystem evaluations built
# via self.lib.mkSystem, exactly as hosts are). It verifies the grant *logic*
# without booting a desktop. Runtime, VM-boot assertions (e.g. a feature secret
# present at /run on a granting host, absent on a denying one) need a booted
# machine and are added with slice 03.
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
