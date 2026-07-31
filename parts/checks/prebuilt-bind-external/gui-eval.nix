# Pure-eval sibling of the prebuilt-bind-external VM rig (issue #1, post-Phase-2 step #3): prove
# that the fleet's `bindContractPackage` (ADR-0016) ACCEPTS the full gui-granted variant of the
# external `users` home — i.e. the grant/variant coupling assert (`mkContractPackage` v2 in the
# contract's lib.nix) passes when a host grants gui+signing+workstation over the contractPackage
# baked with gui+signing. No VM boot: this evaluates the bound NixOS config and forces its
# assertions (reading the pre-built manifest), so it de-risks the binding's ACCEPTANCE cheaply.
#
# It reads a COMMITTED FIXTURE (a snapshot of the real gui contractPackage manifest), not
# `inputs.users.packages.…contractPackage-gui-test` — this models production faithfully (a host
# consumes the pre-built manifest as DATA, never re-evaluating the home) and sidesteps the fleet's
# one-nixpkgs `follows`. See fixtures/gui-contract-package/README.md for the full rationale +
# provenance + regen command. Binds the GENERIC test user ("testuser"), never a real user; needs
# `--override-input contract path:/…/host-user-contract` in a local checkout.
{
  pkgs,
  inputs,
  system,
}:
let
  inherit (inputs) contract;
  inherit (contract.lib) bindContractPackage loadIdentity;
  inherit (inputs.nixpkgs) lib;
  userHome = inputs.users;
  # GENERIC test identity — account "testuser", throwaway password; never the real user.
  identity = loadIdentity (userHome + "/tests/identity.json");
  # The gui-granted pre-built binding artifact, consumed as DATA: a committed snapshot of the real
  # contractPackage-gui-test manifest (granted = [gui signing]). Read purely, no home re-eval.
  cpGui = ./fixtures/gui-contract-package;

  # Minimal seat scaffold, shared with the VM rig (./seat-base.nix): tmpfs root, no bootloader, stub
  # host platform seam. Enough to evaluate a bound account and its assertions — never booted here.
  seatBase = import ./seat-base.nix { inherit system; };

  # Bind the gui variant with the FULL granted set a real gui seat carries. workstation is a
  # non-secret host power (legitimately absent from the baked set — it doesn't change the home),
  # so the coupling assert compares only the secret-bearing subset {signing}, which matches.
  bound = lib.nixosSystem {
    modules = [
      seatBase
      contract.nixosModules.default
      (bindContractPackage {
        contractPackage = cpGui;
        inherit identity;
        grants = {
          gui.enable = true;
          signing.enable = true;
          workstation.enable = true;
        };
      })
    ];
  };

  # Forcing the bound config's assertions reads the pre-built manifest and runs the coupling
  # assert. If any assertion fails (e.g. a grant/variant mismatch), the binding is REJECTED.
  failing = builtins.filter (a: !a.assertion) bound.config.assertions;
  account = bound.config.custom.users.testuser;
in
assert lib.assertMsg (failing == [ ])
  "bindContractPackage must ACCEPT the gui-granted contractPackage, but an assertion failed: ${
    lib.concatMapStringsSep "; " (a: a.message) failing
  }";
# Not vacuous: positively prove the account materialized with the granted features the gui seat
# carries (so an empty/degenerate eval could not pass this silently).
assert lib.assertMsg account.granted.gui.enable "the bound gui account must carry the gui grant";
assert lib.assertMsg account.granted.signing.enable
  "the bound gui account must carry the signing grant";
# …and that the FIXTURE's OWN content flowed through the binding: the manifest's granted gui request
# (requests.gui.desktop) is bridged onto the account, so this reads real fixture data, not just the
# host `grants` arg — a blank/degenerate manifest would not surface the desktop here.
assert lib.assertMsg (
  account.gui.desktop or null == "plasma"
) "the gui request from the fixture manifest must bridge onto the bound account (desktop=plasma)";
pkgs.runCommand "prebuilt-bind-external-gui-eval-ok" { } "touch $out"
