{ inputs, self, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    {
      checks = {
        affine = import ./affine {
          inherit pkgs inputs self;
        };
        networking = import ./networking {
          inherit pkgs inputs self;
        };
        annas_opds = import ./annas-opds {
          inherit pkgs;
        };
        # jmap_bridge VM check moved to the bridge's own repo
        # (inputs.jmap-bridge.checks); its CI owns the round-trip test now.
        # The contract's OWN conformance suite (ADR-0020 Q5), surfaced from the contract
        # flake so this repo's `nix flake check` runs it too. Synthetic users × the
        # contract umbrella, no host repo — the generic proof of the contract's promises.
        contract_conformance = inputs.contract.checks.${system}.conformance;
        # Host INTEGRATION (ADR-0015): the host bindings realize the contract on the real
        # manifest — display rendering, emacs glue, platform resolver, the gui union.
        host_user_contract = import ./host-user-contract {
          inherit pkgs self;
        };
        # Runtime VM smoke for the gui-session union (ADR-0019): one host, two gui users
        # with different sessions ⇒ the host's display binding offers both plasma sessions.
        host_user_contract_vm = import ./host-user-contract-vm {
          inherit pkgs self inputs;
        };
        # The host-side COHERENCE GATE (ADR-0020 Q5): the real fleet ties back to the
        # contract's conformance suite (the display binding is wired wherever the contract
        # decides a surface is needed; real exposed-traits are archetype-covered).
        host_fleet_coherence = import ./host-user-contract-matrix {
          inherit pkgs self;
        };
      };
    };
}
