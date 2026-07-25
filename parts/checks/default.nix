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
        # The pre-built binding path (bindContractPackage, ADR-0016) is proven generically by the
        # contract's OWN conformance (`contract_conformance` below); the fleet-side external-bind
        # rig (`prebuilt_bind_external` + its gui-eval sibling) was retired with ADR-0026, which
        # moved `bindContractPackage` to the contract's `internal` surface and made the turnkey
        # `bindContractUser` (hosts/default.nix) the sole public consumer bind.
        # jmap_bridge VM check moved to the bridge's own repo
        # (inputs.jmap-bridge.checks); its CI owns the round-trip test now.
        # The contract's OWN conformance suite (contract ADR-0004 Q5), surfaced from the contract
        # flake so this repo's `nix flake check` runs it too. Synthetic users × the
        # contract umbrella, no host repo — the generic proof of the contract's promises.
        contract_conformance = inputs.contract.checks.${system}.conformance;
        # The former `host_user_contract` integration check bound the in-tree inline-user
        # `self.users.inkpotmonkey.manifest` (the mkHostFacts host-side eval path) and the retired
        # `workstation` grant — both removed by the ADR-0024/0026 turnkey cutover. Hosts now bind the
        # external `users` flake via `bindContractUser`, and the contract's own conformance owns the
        # grant→feature proofs, so the inline-user path and this check are retired.
        # The gui-union runtime VM moved into the contract's own suite (contract ADR-0004:
        # checks.<system>.conformance-vm there). It uses a test-only display binding, so
        # it no longer covers this fleet's gui.nix display binding; re-surface it from
        # inputs.contract.checks once the contract is published with that check if a
        # fleet-side runtime smoke is wanted.
        # The host-side COHERENCE GATE (contract ADR-0004 Q5): the real fleet ties back to the
        # contract's conformance suite (the display binding is wired wherever the contract
        # decides a surface is needed; real exposed-traits are archetype-covered).
        host_fleet_coherence = import ./host-user-contract-matrix {
          inherit pkgs self;
        };
        # Presence-aware git-annex replication alerting (palimpsest#60): on-demand hosts
        # suppress stale/absent metrics (a closed laptop lid must not page) and alert
        # only on fresh faults, while always-on hosts keep the strict staleness check.
        git_annex_alert = import ./git-annex-alert {
          inherit pkgs self inputs;
        };
        # Restic backup status metrics (Workstream D): a disabled-but-owned off-site job
        # still publishes backup_restic_enabled=0 so the Backups board shows it off, not
        # missing.
        backup_status = import ./backup-status {
          inherit pkgs self inputs;
        };
        # Supernote fork Private Cloud server (ADR-0031, palimpsest#92): runs the real
        # packaged server, drives a login/bootstrap end-to-end, and proves the MCP port is
        # firewalled off the LAN while the sync port is reachable.
        supernote = import ./supernote {
          inherit pkgs self inputs;
        };
        # The ereader round-trip (ADR-0031 v2, palimpsest#107): one-shot send from
        # library/ereader-outbox/, store→library/ereader/ mirror-down, durable device deletes via a
        # persisted baseline, and the store-loss guard — all driven off device-initiated syncs.
        supernote_ereader = import ./supernote/ereader.nix {
          inherit pkgs self inputs;
        };
      };
    };
}
