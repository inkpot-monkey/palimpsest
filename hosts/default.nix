{
  self,
  inputs,
  ...
}:
let
  inherit (self.lib) mkSystem mkPiSystem;

  # Turnkey host-side bind (contract ADR-0025): a host declares its `contract.affordances` ONCE
  # and binds each user BY NAME; the contract derives the grant as `affordances ∩ offer` (the
  # user's offer is published in the pinned `users` flake's `contractUsers` index), selects the
  # maximal baked variant, and delegates to bindContractPackage. This replaces the hand-rolled
  # bindContractPackage + loadIdentity + per-host grant matrix — the host holds ZERO users-repo
  # internals (no package names, variant labels or identity paths). Named `bindUserTurnkey` (NOT
  # `bindContractUser` — that is the contract's public consumer bind this delegates to; `traceUser`
  # is its distinct headless inspector).
  bindUserTurnkey =
    username:
    inputs.contract.lib.bindContractUser {
      inherit username;
      usersFlake = inputs.users;
    };

  # Server seat — inkpotmonkey administers it (sudo) and runs containers, no gui. Intersected with
  # inkpotmonkey's offer this selects the base variant and confers wheel + docker/podman (the atomic
  # capabilities that replaced the retired `workstation` role, ADR-0024). The contract adds the login
  # account, groups and authorized keys; nothing else is needed host-side — the pre-built home carries
  # its own packages and the login shell defaults to bashInteractive.
  serverAffordances.contract.affordances = {
    sudo.enable = true;
    containers.enable = true;
  };

  # GUI workstation seat — the server affordances plus gui, so the intersection with inkpotmonkey's
  # offer selects the gui variant and turns on the shared display surface + input groups (the DE is
  # the seat's own binding, modules/nixos/profiles/gui.nix; the contract's realization links
  # the XDG portal/desktop dirs). virtualization is intentionally absent — inkpotmonkey's offer no
  # longer includes it.
  guiAffordances.contract.affordances = {
    gui.enable = true;
    sudo.enable = true;
    containers.enable = true;
  };
in
{
  flake.nixosConfigurations = {
    stargazer = mkSystem {

      modules = [
        ./stargazer/configuration.nix
        guiAffordances
        (bindUserTurnkey "inkpotmonkey")
      ];
    };

    weedySeadragon = mkSystem {

      modules = [
        ./weedySeadragon/configuration.nix
        guiAffordances
        # inkpotmonkey (gui variant) and eyeofalligator, both bound turnkey from the `users`
        # flake. eyeofalligator co-administers this laptop; the clamp drops the wheel it declares
        # in its identity, so its offer includes sudo and the host affords it ⇒ wheel is conferred
        # by the grant (contract ADR-0001 threat model). eyeofalligator's HOST-side setup (steam,
        # flatpak, printing, …) — which the pre-built home cannot carry — lives in the module below.
        (bindUserTurnkey "inkpotmonkey")
        (bindUserTurnkey "eyeofalligator")
        ./weedySeadragon/eyeofalligator.nix
        # The break-glass admin account (declared in ./weedySeadragon/configuration.nix) is a
        # contract user too but is NOT in the `users` flake, so it is not turnkey-bound; its wheel
        # is clamped unless granted, so grant sudo directly to keep root if the primary login breaks.
        { custom.users.admin.granted.sudo.enable = true; }
      ];
    };

    sawtoothShark = mkSystem {

      modules = [
        ./sawtoothShark/configuration.nix
        guiAffordances
        (bindUserTurnkey "inkpotmonkey")
      ];
    };

    # Note: To build the SD image for porcupineFish manually, run:
    # nix build '.#nixosConfigurations.porcupineFish.config.system.build.images.sd-card'
    # just deploy porcupineFish
    # nixos-rebuild --target-host porcupineFish --sudo --ask-sudo-password switch --flake .#porcupineFish
    porcupineFish = mkPiSystem {

      specialArgs = {
        homeManagerInput = inputs.home-manager-25_11;
      };
      modules = [
        ./porcupineFish/configuration.nix
        # Turnkey base bind: the contractPackage is a pre-built activate script, home-manager-
        # version-agnostic, so the Pi's separate home-manager-25_11 pin (specialArgs above) is
        # irrelevant for inkpotmonkey.
        serverAffordances
        (bindUserTurnkey "inkpotmonkey")
        # blocky removed here (ADR-0023) — the Pi-only module swap it needed went with it.
      ];
    };

    # just deploy kelpy
    # nixos-rebuild --target-host kelpy --sudo --ask-sudo-password switch --flake .#kelpy
    #
    # Initial build on a fresh VPS (before inkpotmonkey user exists):
    # nixos-rebuild --target-host root@<ip> switch --flake .#kelpy
    kelpy = mkSystem {

      modules = [
        ./kelpy/configuration.nix
        serverAffordances
        (bindUserTurnkey "inkpotmonkey")
      ];
    };

    potbelliedSeahorse = mkSystem {

      modules = [
        ./potbelliedSeahorse/configuration.nix
        serverAffordances
        (bindUserTurnkey "inkpotmonkey")
      ];

    };

    # Turing Pi RK1 nodes (RK3588, 32 GB). Shared config in ./rk1/common.nix;
    # each node differs only by hostname + enabled profiles.
    #
    # Deploy (build on the node itself — aarch64):
    # nixos-rebuild switch --flake .#rk1a \
    #   --target-host nixos@<ip> --build-host nixos@<ip> --use-remote-sudo
    rk1a = mkSystem {
      modules = [
        ./rk1/common.nix
        serverAffordances
        (bindUserTurnkey "inkpotmonkey")
        {
          networking.hostName = "rk1a";
          custom.profiles.monitoring-client.enable = true;

          # rk1a is the voice node (ADR-0027). The local llama.cpp LLM stack was retired
          # (its ~15 GB GGUF and ~20 GB of pinned RAM are gone), freeing the node to take
          # over Home Assistant + local Wyoming voice (STT/TTS) — moved here off rk1b with
          # fresh state (it was a PoC). The wake word runs on the phone. See
          # modules/nixos/profiles/homeassistant.nix. The real-time STT is the small
          # base-int8 faster-whisper; voice latency isn't critical so it's fine on CPU.
          # Voice is light on disk (no GGUF), so it fits rk1a's 29 GB eMMC without an NVMe.
          # (Heavyweight WhisperX batch transcription lives on stargazer now — its Zen 5 CPU
          # is ~8-10x faster than the A76s for large-v3, so an hour of audio takes ~15 min
          # vs ~2h.)
          custom.profiles.homeassistant.enable = true;
          # Codify the Assist-pipeline wiring (Wyoming STT/TTS) as a fail-loud,
          # idempotent post-start oneshot instead of a manual UI step. Owner
          # username defaults to `admin`; password from the ha_owner_password sops
          # secret. See modules/nixos/profiles/homeassistant.nix + the runbook.
          custom.profiles.homeassistant.provision.enable = true;
        }
      ];
    };

    rk1b = mkSystem {
      modules = [
        ./rk1/common.nix
        # The music library as a git-annex repo, replicated to kelpy so slskd can share it
        # (ADR-0028). rk1b-only: rk1a has no library.
        ./rk1/git-annex.nix
        # The Supernote document library as a second git-annex repo (ADR-0031, #90):
        # git-annex owns the corpus tree, replicated to kelpy and — unlike music — backed up
        # offsite. Adds to the same services.git-annex enabled by git-annex.nix above.
        ./rk1/library.nix
        serverAffordances
        (bindUserTurnkey "inkpotmonkey")
        ({ config, ... }: {
          networking.hostName = "rk1b";
          # rk1b is the media + monitoring node (ADR-0027). The local llama.cpp LLM stack is
          # retired fleet-wide — the cloud `qwen3-coder` (DeepInfra) via kelpy's LiteLLM is
          # what remains. Home Assistant + Wyoming voice moved off this node to rk1a (voice
          # needs no disk; media does, and the NVMe is here). rk1b keeps its `tailscale` block
          # (shared common.nix) — the Vector monitoring receiver still needs the tailnet.

          # NVMe (Samsung PM981, 512G, fitted Jun 2026): /nix on the `nixstore` partition (128G)
          # so the store has room for build offload (this node is the fleet's aarch64 remote
          # builder — see modules/nixos/profiles/pi-builder.nix), keeping the 29G eMMC from
          # overflowing. The `rk1cache` partition (349G) mounts at /var/cache for telemetry,
          # paperless, and other data services (repartitioned Jun 2026; was 400G nixstore +
          # 77G rk1cache — inverted since the store only needs ~10G and data needs the room).
          custom.rk1.nvme.enable = true;
          custom.rk1.nvme.relocateNixStore = true;

          # Navidrome — the friends' shared music platform (ADR-0027). Media node: the
          # library (/var/cache/music) and DB (/var/cache/navidrome) live on the NVMe
          # /var/cache subtree (durable across the tmpfs-root reboot). Tailnet-only,
          # fronted by kelpy's Caddy at music.<domain>; admin user bootstrapped from the
          # navidrome_admin_password sops secret. See modules/nixos/profiles/navidrome.nix
          # and the `music` entry in parts/settings.nix.
          custom.profiles.navidrome.enable = true;
          # Provision friend/listener accounts declaratively from the sops `users` map
          # (profiles/navidrome.yaml) via Navidrome's native API — see navidrome.nix.
          custom.profiles.navidrome.provisionUsers = true;

          # Beets ingest pipeline (ADR-0027, #43): a systemd path unit watches
          # /var/cache/music-inbox and fires a throttled `beet import` that fingerprints
          # (Chromaprint/AcoustID), tags from MusicBrainz, fetches art, de-dupes, and files
          # confident matches into the /var/cache/music library (Navidrome's watcher scans
          # them in); uncertain ones quarantine to /var/cache/music-review. Runs as the
          # navidrome user so filed tracks are library-owned. See modules/nixos/profiles/beets.nix.
          custom.profiles.beets.enable = true;

          # Music Assistant — the library-plane brain (ADR-0031). Reads Navidrome (over loopback,
          # co-located here) and pushes audio to porcupineFish's snapserver in external-server mode,
          # so the Navidrome library plays out the Pi's speakers, controlled from Home Assistant on
          # rk1a. State on the NVMe /var/cache/music-assistant; providers provisioned from the sops
          # navidrome `users` map. See modules/nixos/profiles/music-assistant.nix.
          custom.profiles.music-assistant.enable = true;

          # Supernote fork Private Cloud server (ADR-0031, #92): the device sync endpoint the
          # Nomad binds over plain HTTP on the home LAN (rk1b shares 192.168.1.0/24). Runs as a
          # private `supernote` user with a persisted, rebuildable store (/var/lib/supernote), and
          # bootstraps the single account from the shared credential secret (profiles/library.yaml).
          # LAN-direct, so it is NOT in settings.services / not Caddy-fronted; the MCP port is
          # firewalled off (v1). See modules/nixos/profiles/supernote.nix. Stump (#93) that turns
          # this into a browsable document library is a separate ticket.
          custom.profiles.supernote.enable = true;
          # The ereader round-trip (ADR-0031 v2, #107): `library/ereader/` (/var/cache/library/ereader)
          # is a downward mirror of what the device holds (durable device-side deletes), and dropping a
          # PDF/EPUB into the sibling `ereader-outbox/` publishes it once onto the device on the next
          # device-initiated sync. Couples to the library tree (hosts/rk1/library.nix), which is why it
          # lives behind its own flag — see modules/nixos/profiles/supernote.nix.
          custom.profiles.supernote.ereader.enable = true;

          # Off-host uptime watcher (Gatus): rk1b is always-on and not kelpy, so it
          # can observe kelpy failing. Probes the fleet + alerts to #infra-alerts.
          # See ADR-0019 / modules/nixos/profiles/monitoring/watcher.nix.
          # Monitoring server (moved from kelpy — kelpy's shared-disk write IO was
          # flagged as resource abuse; NVMe on rk1b absorbs it cleanly). VL/VM data
          # dirs redirect to /var/cache (NVMe) via BindPaths. See ADR-0021.
          custom.profiles.monitoring-server.enable = true;
          custom.profiles.monitoring-client.enable = true;
          # Off while rsync.net is unreachable fleet-wide (meant to return); reportJobs
          # keeps the telemetry backup visible on the Backups board as a disabled edge.
          custom.profiles.backup.monitoringTelemetry.enable = false;
          custom.profiles.backup.reportJobs = [ "telemetry" ];

          # DMARC aggregate-report metrics. Co-located with the monitoring server so
          # it's scraped over loopback; polls the `dmarc` mailbox on kelpy's Stalwart
          # via IMAP (imapHost default). Secret dmarc_imap_password lives in
          # monitoring.yaml (rk1b-readable).
          custom.profiles.monitoring-dmarc.enable = true;
          # White-box DMARC alert: query VM (local) and message #infra-alerts when mail
          # fails DMARC (own mail rejected at p=reject, or spoofing). Webhook = the
          # watcher's gatus-webhook-url template (rk1b doesn't run matrix.infraAlerts).
          custom.profiles.monitoring-dmarc-alert = {
            enable = true;
            webhookUrlFile = config.custom.profiles.monitoring-watcher.webhookUrlFile;
          };

          # SMTP TLS Reporting (TLSRPT / RFC 8460). Same shape as the DMARC pair:
          # poll the `tlsrpt` mailbox on kelpy's Stalwart (secret tlsrpt_imap_password
          # in monitoring.yaml), export smtp_tls_report_* via the node-exporter
          # textfile collector, and alert #infra-alerts when a report records failed
          # TLS sessions. Routing: dns app repoints _smtp._tls rua postmaster@→tlsrpt@.
          custom.profiles.monitoring-tlsrpt.enable = true;
          custom.profiles.monitoring-tlsrpt-alert = {
            enable = true;
            webhookUrlFile = config.custom.profiles.monitoring-watcher.webhookUrlFile;
          };

          # Second fleet DNS resolver (ADR-0023): rk1b is the tailnet's other global
          # nameserver alongside kelpy, replacing the drifted porcupineFish. No module
          # swap needed — rk1b is built with mkSystem (main nixpkgs → blocky 0.30). Also
          # makes rk1b self-resolve via its own blocky (nameservers = 127.0.0.1).
          custom.profiles.blocky.enable = true;

          # Off-host uptime watcher (Gatus): rk1b is always-on and not kelpy, so it
          # can observe kelpy failing. Probes the fleet + alerts to #infra-alerts.
          # See ADR-0019 / modules/nixos/profiles/monitoring/watcher.nix.
          custom.profiles.monitoring-watcher.enable = true;
          # Out-of-band web-push alerter (ADR-0020): fires the phone when the Matrix
          # delivery path itself is down. topic + publish_token from monitoring.yaml.
          custom.profiles.monitoring-watcher.outOfBand.enable = true;

          # White-box unit-state alerts for the services that moved here from kelpy.
          # webhookUrlFile comes from the watcher's sops template (rk1b doesn't run
          # matrix.infraAlerts, which is kelpy-only).
          custom.profiles.monitoring-unit-state = {
            enable = true;
            webhookUrlFile = config.custom.profiles.monitoring-watcher.webhookUrlFile;
            units = [
              "grafana.service"
              "victoriametrics.service"
              "victorialogs.service"
              "vector.service"
            ];
          };

          # git-annex replication watcher (palimpsest#60): rk1b is authoritative for the
          # music library, so a silent stop here means nothing beets files ever reaches
          # kelpy for slskd to seed. Same webhook story as the checks above.
          custom.profiles.monitoring-git-annex-alert = {
            enable = true;
            webhookUrlFile = config.custom.profiles.monitoring-watcher.webhookUrlFile;
          };
        })
      ];
    };
  };
}
