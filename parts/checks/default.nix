{ inputs, self, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    {
      checks = {
        affine = import ./affine {
          inherit pkgs inputs self;
        };
        # ADR-0019 slice 04: monitor-by-default guard over settings.services — opt-outs
        # need a reason, and every monitored service must resolve to a buildable probe.
        uptime_monitoring = import ./uptime-monitoring {
          inherit pkgs self;
        };
        networking = import ./networking {
          inherit pkgs inputs self;
        };
        annas_opds = import ./annas-opds {
          inherit pkgs;
        };
        # Operator-read helper (users/inkpotmonkey/home/secret.nix): pure-derivation
        # regression over the key->extract logic + `-l` listing. Guards the dotted-key
        # bug (the `.`->`/` rewrite that made apikey@api.example.com unreachable).
        secret_read = import ./secret-read {
          inherit pkgs self;
        };
        # Claude relay (ADR-0018) slice 01: allowlist-gated echo over a minimal
        # tuwunel homeserver. The relay's mechanics are proven here (stub-driven in
        # later slices) so an AFK agent can verify via `nix flake check`.
        claude_relay = import ./claude-relay {
          inherit pkgs self;
        };
        # Per-bridge management-DM auto-provisioning (dm-provision.nix): room
        # creation + invite + m.direct + welcome (unencrypted) / encryption
        # (encrypted) + idempotency, against a minimal tuwunel.
        matrix_dm_provision = import ./dm-provision {
          inherit pkgs self;
        };
        # jmap_bridge VM check moved to the bridge's own repo
        # (inputs.jmap-bridge.checks); its CI owns the round-trip test now.
        # The contract's OWN conformance suite (contract ADR-0004 Q5), surfaced from the contract
        # flake so this repo's `nix flake check` runs it too. Synthetic users × the
        # contract umbrella, no host repo — the generic proof of the contract's promises.
        contract_conformance = inputs.contract.checks.${system}.conformance;
        # Host INTEGRATION (contract ADR-0001): the host bindings realize the contract on the real
        # manifest — display rendering, emacs glue, platform resolver, the gui union.
        host_user_contract = import ./host-user-contract {
          inherit pkgs self;
        };
        # The gui-union runtime VM moved into the contract's own suite (contract ADR-0004:
        # checks.<system>.conformance-vm there). It uses a test-only display binding, so
        # it no longer covers this fleet's gui-desktop.nix; re-surface it from
        # inputs.contract.checks once the contract is published with that check if a
        # fleet-side runtime smoke is wanted.
        # The host-side COHERENCE GATE (contract ADR-0004 Q5): the real fleet ties back to the
        # contract's conformance suite (the display binding is wired wherever the contract
        # decides a surface is needed; real exposed-traits are archetype-covered).
        host_fleet_coherence = import ./host-user-contract-matrix {
          inherit pkgs self;
        };
      };
    };
}
