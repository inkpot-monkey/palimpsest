{
  self,
  inputs,
  ...
}:
let
  inherit (self.lib) mkSystem mkPiSystem;
  # Grant-as-data (contract ADR-0002, slice 16): a host grants a user's features here, as data,
  # next to where it binds the user — never by importing a self-granting variant. This
  # is the fleet's grant matrix; `granted.*` is host-write-only, the user never sets it.
  grant = user: features: { custom.users.${user}.granted = features; };
in
{
  flake.nixosConfigurations = {
    stargazer = mkSystem {

      modules = [
        ./stargazer/configuration.nix
        self.users.inkpotmonkey.manifest
        (grant "inkpotmonkey" {
          gui.enable = true;
          workstation.enable = true;
          virtualization.enable = true;
          signing.enable = true;
        })
      ];
    };

    weedySeadragon = mkSystem {

      modules = [
        ./weedySeadragon/configuration.nix
        self.users.inkpotmonkey.manifest
        self.users.eyeofalligator
        (grant "inkpotmonkey" {
          gui.enable = true;
          workstation.enable = true;
          virtualization.enable = true;
        })
        # eyeofalligator co-administers this laptop and had sudo pre-clamp (its identity
        # declares wheel); the clamp drops untrusted identity groups, so its sudo must be
        # an explicit grant now (contract ADR-0001 threat model; cloud-review finding).
        (grant "eyeofalligator" {
          gui.enable = true;
          sudo.enable = true;
        })
        # The break-glass admin account (declared in ./weedySeadragon/configuration.nix)
        # is a contract user too, so its wheel is also clamped unless granted. Grant sudo
        # so the recovery account keeps root if the primary login breaks.
        (grant "admin" { sudo.enable = true; })
      ];
    };

    sawtoothShark = mkSystem {

      modules = [
        ./sawtoothShark/configuration.nix
        self.users.inkpotmonkey.manifest
        (grant "inkpotmonkey" {
          gui.enable = true;
          workstation.enable = true;
          virtualization.enable = true;
          signing.enable = true;
        })
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
        self.users.inkpotmonkey.manifest
        (grant "inkpotmonkey" { workstation.enable = true; })
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
        self.users.inkpotmonkey.manifest
        # kelpy is exposed: it gets workstation (docker/podman/wheel) but no
        # secret-bearing feature. Now that the grant is explicit here, dropping it is a
        # one-line change (see the exposed-host note in contract/realization.nix).
        (grant "inkpotmonkey" { workstation.enable = true; })
      ];
    };

    potbelliedSeahorse = mkSystem {

      modules = [
        ./potbelliedSeahorse/configuration.nix
        self.users.inkpotmonkey.manifest
        (grant "inkpotmonkey" { workstation.enable = true; })
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
        self.users.inkpotmonkey.manifest
        (grant "inkpotmonkey" { workstation.enable = true; })
        {
          networking.hostName = "rk1a";
          custom.profiles.monitoring-client.enable = true;
          # The local llama.cpp LLM stack was retired (ADR-0027): the ~15 GB GGUF and its
          # ~20 GB of pinned RAM are gone, freeing the node. rk1a is earmarked as the voice
          # node (HA + Wyoming moved off rk1b) — that migration lands separately.
        }
      ];
    };

    rk1b = mkSystem {
      modules = [
        ./rk1/common.nix
        self.users.inkpotmonkey.manifest
        (grant "inkpotmonkey" { workstation.enable = true; })
        ({ config, ... }: {
          networking.hostName = "rk1b";
          # rk1b is the voice node. The local llama.cpp LLM stack is retired fleet-wide
          # (ADR-0027) — the cloud `qwen3-coder` (DeepInfra) via kelpy's LiteLLM is what
          # remains. Home Assistant + local Wyoming voice (STT/TTS); the wake word runs on the phone.
          # See modules/nixos/profiles/homeassistant.nix. The real-time STT here is the small
          # base-int8 faster-whisper; voice latency isn't critical so it's fine on CPU.
          # (Heavyweight WhisperX batch transcription lives on stargazer now — its Zen 5 CPU is
          # ~8-10x faster than the A76s for large-v3, so an hour of audio takes ~15 min vs ~2h.)
          custom.profiles.homeassistant.enable = true;

          # NVMe (Samsung PM981, 512G, fitted Jun 2026): /nix on the `nixstore` partition (128G)
          # so the store has room for build offload (this node is the fleet's aarch64 remote
          # builder — see modules/nixos/profiles/pi-builder.nix), keeping the 29G eMMC from
          # overflowing. The `rk1cache` partition (349G) mounts at /var/cache for telemetry,
          # paperless, and other data services (repartitioned Jun 2026; was 400G nixstore +
          # 77G rk1cache — inverted since the store only needs ~10G and data needs the room).
          custom.rk1.nvme.enable = true;
          custom.rk1.nvme.relocateNixStore = true;

          # Off-host uptime watcher (Gatus): rk1b is always-on and not kelpy, so it
          # can observe kelpy failing. Probes the fleet + alerts to #infra-alerts.
          # See ADR-0019 / modules/nixos/profiles/monitoring/watcher.nix.
          # Monitoring server (moved from kelpy — kelpy's shared-disk write IO was
          # flagged as resource abuse; NVMe on rk1b absorbs it cleanly). VL/VM data
          # dirs redirect to /var/cache (NVMe) via BindPaths. See ADR-0021.
          custom.profiles.monitoring-server.enable = true;
          custom.profiles.monitoring-client.enable = true;
          custom.profiles.backup.monitoringTelemetry.enable = true;

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
        })
      ];
    };
  };
}
