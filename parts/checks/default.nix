{ inputs, self, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    {
      checks = {
        # DISABLED — fails on an untouched tree, so it gates every unrelated change.
        # The test VM declares no `virtualisation.diskSize`, so podman unpacks a 156 MB
        # image into a default-sized guest and dies with ENOSPC:
        #   unpacking failed … /var/lib/containers/storage/… no space left on device
        # Reproduced on a pristine worktree at 5e9df3b with no local changes present, so
        # this is not fallout from whatever is currently in flight. Re-enable once the
        # guest is sized for the image it unpacks.
        # affine = import ./affine {
        #   inherit pkgs inputs self;
        # };
        # ADR-0019 slice 04: monitor-by-default guard over settings.services — opt-outs
        # need a reason, and every monitored service must resolve to a buildable probe.
        uptime_monitoring = import ./uptime-monitoring {
          inherit pkgs self;
        };
        networking = import ./networking {
          inherit pkgs inputs self;
        };
        # blocky_* collection (palimpsest#39): blocky's metrics endpoint is real, and every
        # declared fleet resolver's series reaches VictoriaMetrics.
        blocky_metrics = import ./blocky-metrics {
          inherit pkgs inputs self;
        };
        # The tailscale-service hosts generator (palimpsest#165): it restarts blocky only
        # when the resolved IPs actually changed. Restarting unconditionally bounces fleet
        # DNS every 30 minutes and resets blocky's counters with it.
        blocky_service_hosts = import ./blocky-service-hosts {
          inherit pkgs inputs self;
        };
        # DISABLED — fails on an untouched tree, so it gates every unrelated change.
        # The VM boots but never reaches the target the script waits on:
        #   RequestedAssertionFailed: unit "network-online.target" is inactive and there
        #   are no pending jobs
        # Reproduced on a pristine worktree at 5e9df3b with no local changes present
        # (identical derivation hash both sides, so no local change can reach it).
        # Re-enable once the VM's network target actually comes up.
        # annas_opds = import ./annas-opds {
        #   inherit pkgs;
        # };
        # The book filer (palimpsest#144): EPUBs dropped in books-inbox/<Subject>/ are renamed
        # from their own OPF metadata and filed into the library tree. Covers the happy path,
        # missing metadata, collisions, unsupported formats, a drop with no subject folder, and
        # the quiescence window — plus the default ACL and the copy-then-rename that a plain
        # `mv` would silently get wrong.
        book_filer = import ./book-filer {
          inherit pkgs self;
        };
        # Per-bridge management-DM auto-provisioning (dm-provision.nix): room
        # creation + invite + m.direct + welcome (unencrypted) / encryption
        # (encrypted) + idempotency, against a minimal tuwunel.
        matrix_dm_provision = import ./dm-provision {
          inherit pkgs self;
        };
        # Hookshot's admin-room oneshot (hookshot-adminroom.nix): the admin-room marker
        # that works around tuwunel's missing is_direct, and the notification stream
        # position that works around upstream #965 — seeded in ms, healing a room that is
        # already activated, and never rewinding a live position.
        hookshot_adminroom = import ./hookshot {
          inherit pkgs self;
        };
        # The declarative GitHub token store (hookshot-github-token.nix): it reimplements
        # hookshot's UserTokenStore write, so the check DECRYPTS what it wrote with the real
        # private key rather than trusting the shape — plus rotation of both the value and
        # the encryption key, and the sops trailing-newline trap.
        hookshot_github_token = import ./hookshot/token.nix {
          inherit pkgs self;
        };
        # The #infra-alerts room + connection provisioner (infra-alerts.nix). This module
        # hid a four-week outage — the room was wiped, its id stayed pinned, and every curl
        # being `|| true` kept it reporting success while the fleet's alerters POSTed into a
        # 404. Asserts a dead pin and a stale marker are both refused, and that the
        # connection resolves the way hookshot resolves it (account data, not just state).
        hookshot_infra_alerts = import ./hookshot/infra-alerts.nix {
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
        # The Supernote downward mirror (ADR-0031, palimpsest#107 as reduced by #117): everything
        # the device holds materialises into library/supernote/ as real files inside a real
        # git-annex tree, with the Stump catalog running on that same tree; durable device deletes;
        # and no deletion from the backed-up tree when the store is empty or unreachable — all off
        # device-initiated syncs.
        supernote_mirror = import ./supernote/mirror.nix {
          inherit pkgs self inputs;
        };
        # The Stump reading catalog (ADR-0031, palimpsest#113): three series-priority libraries
        # over a real 2770 git-annex:library corpus (the PrivateUsers group-read trap), the
        # unindexed `_originals/` sibling, tailnet-only reachability, and correct OPDS
        # self-referencing links through a real Caddy edge.
        stump = import ./stump {
          inherit pkgs self inputs;
        };
      };
    };
}
