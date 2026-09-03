# The fleet-side RUNTIME proof of the turnkey bind (contract ADR-0025, issue #1's cutover).
#
# WHAT NOTHING ELSE PROVES. The contract's own conformance suite proves the binding path
# generically, but it binds a SYNTHETIC contractPackage — an `activate` that writes a marker — and
# it must, because the contract flake inputs no home-manager and cannot build a home (its ADR-0002).
# This repo's checks prove the fleet EVALUATES. So the one thing neither side covers is the seam
# between them: that a REAL contractPackage, published by the pinned `users` flake and selected by
# `bindContractUsers`, actually boots — the account realizes, the grant lands as groups, and the
# home's own activation runs to completion on a machine.
#
# Built on `testing.mkSeatHarness`, the seat-VM harness the contract publishes at its flake surface
# precisely so a consumer can boot a contract seat without naming a path inside `conformance/`.
# Before that output existed this test could only have re-authored the seat host (bootloader off,
# tmpfs root, stateVersion, umbrella import) and then drifted from it.
#
# DELIBERATELY HEADLESS — `modes = [ ]`, so the seat runs the floor (`cli`) and the bind selects
# inkpotmonkey's terminal home. A gui seat would select the graphical home, whose closure is the
# desktop, the dev toolchain, the AI CLIs and emacs: a far larger build for a proof about the
# BINDING, which is identical either way. The mode-selection logic itself is the contract's own
# matrix to prove, and it does.
#
# AFFORDED SUDO AND NOTHING ELSE. `containers` would confer the docker/podman groups, which only
# exist on a host that enables those runtimes — turning a bind proof into a container-runtime
# fixture. That grant→groups mapping is registry data the contract's conformance already covers per
# feature; what is fleet-specific here is that a real published package binds and activates.
{
  pkgs,
  inputs,
  ...
}:
let
  system = pkgs.stdenv.hostPlatform.system;

  harness = inputs.contract.testing.mkSeatHarness {
    inherit pkgs system;
    contractModule = inputs.contract.nixosModules.default;
  };
in
harness.mkSeatVM {
  name = "contract-seat-prebuilt-users";
  # No greeter: this is a BUILD-TIME binding seat (the home is selected and baked at eval), which
  # is exactly how every host in this fleet binds. The runtime greeter is a different posture and
  # the contract owns its proofs.
  greeter = false;
  # A headless box: the floor is implicit and unexcludable, so this says the seat runs `cli` alone.
  modes = [ ];

  seat.imports = [
    (inputs.contract.lib.bindContractUsers {
      source = inputs.users;
      users.inkpotmonkey.sudo = true;
    })
  ];

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # 1. THE ACCOUNT REALIZED, from an identity this repo never wrote down: the index the `users`
    #    flake publishes carried it, and the bind materialized it.
    machine.succeed("id inkpotmonkey")

    # 2. THE GRANT LANDED. `wheel` is conferred by the sudo affordance stated at the bind — and by
    #    nothing else, since the privileged-group clamp drops what a user declares for itself.
    groups = machine.succeed("id -nG inkpotmonkey").split()
    assert "wheel" in groups, f"sudo was afforded but wheel is absent: {groups}"

    # 3. THE HOME'S OWN ACTIVATION RAN. This is the claim that needs a real package: the unit runs
    #    `runuser -l inkpotmonkey -c <contractPackage>/activate`, i.e. home-manager's real
    #    activation inside a login session, ordered before multi-user.target. A synthetic marker
    #    package cannot fail the way this can.
    machine.succeed("systemctl is-active contract-activate-inkpotmonkey")

    # 4. …AND PUT THE HOME'S CONTENT ON DISK. The terminal home enables programs.git, so its
    #    generated config is the artifact that separates "the unit exited 0" from "the home is
    #    actually there".
    machine.succeed("test -f /home/inkpotmonkey/.config/git/config")
    machine.succeed("test -d /home/inkpotmonkey/.nix-profile || test -d /home/inkpotmonkey/.local/state/nix/profiles")
  '';
}
