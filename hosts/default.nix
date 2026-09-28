{
  self,
  inputs,
  ...
}:
let
  inherit (self.lib) mkSystem mkPiSystem;

  # Turnkey host-side bind (contract ADR-0025, ADR-0026). A host states TWO separate things, and
  # the contract keeps them apart on purpose:
  #
  #   `contract.modes`  — the session shapes THE BOX can run. A capability of the machine, said
  #                       once, about nobody. The floor (`cli`) is implicit and unexcludable, so a
  #                       headless host says nothing at all.
  #   `affordances`     — what a given ACCOUNT may DO, said per user AT ITS BIND. A decision about
  #                       a person, and now the whole of the grant: a user declares only which
  #                       shapes it runs in and asks for no powers, so there is no user-side offer
  #                       left to intersect with. What is written below IS what is conferred.
  #
  # This replaced one host-wide `contract.affordances` block. Reading a display out of the same
  # namespace as sudo made a seat's capability look like a privilege, which is the split the
  # contract made upstream — `gui` is not a feature any more, it is a mode.
  #
  # `bindContractUsers` takes the host's whole user list in one call, reads the binding index the
  # pinned `users` flake publishes, selects each person's mode, confers what was afforded and
  # realizes the account. The host holds ZERO users-repo internals: no package names, no variant
  # labels, no identity paths.
  bindUsers =
    users:
    inputs.contract.lib.bindContractUsers {
      source = inputs.users;
      inherit users;
    };

  # The operator's account, wherever it is bound: administers the machine and runs containers.
  # These are the atomic capabilities that replaced the retired `workstation` role (contract
  # ADR-0024); `virtualization` is deliberately absent.
  operator = {
    sudo = true;
    containers = true;
  };

  # A GUI seat — the box can run a graphical session, so a user that declares one is bound in it.
  # The DE itself is the seat's own binding (modules/nixos/profiles/gui.nix); the contract only
  # derives that a shared display surface is needed (`contract.display.enabled`) and links the
  # XDG portal/desktop dirs.
  guiSeat.contract.modes = [ "gui" ];
in
{
  flake.nixosConfigurations = {
    stargazer = mkSystem {

      modules = [
        ./stargazer/configuration.nix
        guiSeat
        (bindUsers { inkpotmonkey = operator; })
      ];
    };

    weedySeadragon = mkSystem {

      modules = [
        ./weedySeadragon/configuration.nix
        guiSeat
        # inkpotmonkey and eyeofalligator, both bound from the `users` flake. eyeofalligator
        # co-administers this laptop, so it is afforded sudo — and ONLY sudo: it used to sit under
        # a host-wide affordance block that also carried `containers`, which was incidental to the
        # block's scope rather than anything this person needs. Now that affordances are stated per
        # user, the narrower set is the honest one. Its HOST-side setup (steam, flatpak, printing,
        # …) — which the pre-built home cannot carry — lives in the module below.
        (bindUsers {
          inkpotmonkey = operator;
          eyeofalligator.sudo = true;
        })
        ./weedySeadragon/eyeofalligator.nix
        # The break-glass admin account (declared in ./weedySeadragon/configuration.nix) is a
        # contract user too but is NOT in the `users` flake, so it is not bound from there; its
        # wheel is clamped unless granted, so grant sudo directly to keep root if the primary
        # login breaks.
        { contract.users.admin.granted.sudo = true; }
      ];
    };

    sawtoothShark = mkSystem {

      modules = [
        ./sawtoothShark/configuration.nix
        guiSeat
        (bindUsers { inkpotmonkey = operator; })
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
        (bindUsers { inkpotmonkey = operator; })
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
        (bindUsers { inkpotmonkey = operator; })
      ];
    };

    potbelliedSeahorse = mkSystem {

      modules = [
        ./potbelliedSeahorse/configuration.nix
        (bindUsers { inkpotmonkey = operator; })
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
        (bindUsers { inkpotmonkey = operator; })
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
        (bindUsers { inkpotmonkey = operator; })
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

          # Immich — the personal photo library, replacing the Google Photos/Drive archive.
          # Lands here rather than on kelpy for the same reason the media plane did: kelpy has
          # 4G and no swap, and immich-server peaks ~1.4G importing its geodata on first start.
          # It OOM-looped there and the kernel killed tuwunel and jellyfin alongside it. rk1b
          # has 32G, 15G of zram swap and the NVMe, and both the server and the ML worker are
          # substitutable for aarch64 (checked against cache.nixos.org, not assumed).
          #
          # Media and database both go on the /var/cache NVMe subtree, NOT the tmpfs root —
          # the same placement as Navidrome and Stump — and the profile gates both units on
          # those mounts so neither can win the race against var-cache.mount and write to the
          # ramdisk. Fronted by kelpy's Caddy at immich.<domain>, so DEPLOY KELPY TOO (the
          # same trap stump.nix flags above).
          custom.profiles.immich = {
            enable = true;
            mediaLocation = "/var/cache/immich";
            databaseDir = "/var/cache/postgresql";
            # The owner account, from the `immich_admin_secret` that has sat unused in
            # profiles/media.yaml since before Immich existed here. Also mints the API
            # key the CLI importer needs — which cannot exist until the account does,
            # so this unblocks the photo import as well as the login.
            provision.enable = true;
          };

          # The media stack — gluetun (ProtonVPN), qBittorrent, slskd and Jellyfin. Moved
          # here wholesale off kelpy: the profile is one flag and qBittorrent/slskd share
          # gluetun's network namespace, so it could not be split without refactoring that
          # VPN wiring. Drivers were memory (kelpy has 4G) and write IO — torrent traffic on
          # a shared VPS disk is the resource-abuse flag that already moved monitoring
          # (ADR-0021); here it lands on the NVMe.
          #
          # mediaPath is on /var/cache, NOT the 2G tmpfs root that downloads would fill in
          # minutes — the same placement as Navidrome, Stump and Immich.
          #
          # slskd points at the AUTHORITATIVE library here (Navidrome's MusicFolder), not a
          # replica: that is the whole reason this move pays for itself, and it satisfies
          # slskd's own assertion that the path be an unlock+thin annex repo. kelpy's
          # replica is retired in hosts/kelpy/git-annex.nix.
          #
          # ⚠ Jellyfin transcoding is SOFTWARE-ONLY here and ~3.3x slower than on kelpy —
          # see the jellyfin entry in parts/settings.nix for the measurements and why the
          # RK3588 VPU cannot help.
          custom.profiles.media = {
            enable = true;
            mediaPath = "/var/cache/media";
            # Jellyfin's wizard and libraries, declared rather than clicked. Moving the
            # stack here produced a running Jellyfin sat beside 15G of media with no
            # library pointing at any of it — that state lived only in kelpy's UI, and
            # kelpy's copy turned out to be 14K of nothing, so there was nothing to
            # migrate and no way to notice except by looking.
            jellyfin.provision = {
              enable = true;
              libraries = [
                {
                  name = "Series";
                  type = "tvshows";
                  path = "/var/cache/media/series";
                }
                {
                  name = "Movies";
                  type = "movies";
                  path = "/var/cache/media/movies";
                }
                {
                  name = "Downloads";
                  type = "tvshows";
                  path = "/var/cache/media/downloads";
                }
              ];
            };
            # rk1b's OWN ProtonVPN config, not kelpy's. Two hosts on one WireGuard key
            # repoint each other's endpoint on every handshake and contend for the single
            # NAT-PMP grant, with both units staying green throughout (palimpsest#190).
            # This key was minted for rk1b with NAT-PMP enabled at generation (stash
            # 0ab5214) precisely so the two stacks can run at once.
            vpnSecretFile = "video";
            slskd = {
              enable = true;
              libraryPath = config.services.navidrome.settings.MusicFolder;
            };
          };

          # LiteLLM — the cloud-model proxy (DeepInfra). Moved off kelpy purely for memory
          # (~292M on a 4G host); it holds no state and talks only outward, so relocating it
          # costs nothing. Caddy still fronts it at litellm.<domain>, so consumers see no
          # change of address. Binds 0.0.0.0 + tailscale0 only, like Immich.
          custom.profiles.litellm.enable = true;

          # Music Assistant — the library-plane brain (ADR-0031). Reads Navidrome (over loopback,
          # co-located here) and pushes audio to porcupineFish's snapserver in external-server mode,
          # so the Navidrome library plays out the Pi's speakers, controlled from Home Assistant on
          # rk1a. State on the NVMe /var/cache/music-assistant; providers provisioned from the sops
          # navidrome `users` map. See modules/nixos/profiles/music-assistant.nix.
          custom.profiles.music-assistant.enable = true;

          # Supernote Private Cloud server (ADR-0031, #92): the device sync endpoint the Nomad
          # binds over plain HTTP, on the home LAN (rk1b shares 192.168.1.0/24) or over the
          # tailnet — the device picks, and both reach the same port. Runs as a private
          # `supernote` user with a persisted, rebuildable store (/var/lib/supernote), and
          # bootstraps the single account from the shared credential secret (profiles/library.yaml).
          # Not Caddy-fronted, so it is NOT in settings.services. This comment used to say the MCP
          # port is "firewalled off"; it is not — this host trusts `tailscale0`, so the LLM port is
          # reachable from the tailnet and is gated by the MCP server's own auth instead. See the
          # header of modules/nixos/profiles/supernote.nix.
          custom.profiles.supernote.enable = true;
          # The downward mirror (ADR-0031, #107 as reduced by #117): `library/supernote/`
          # (/var/cache/library/supernote) materialises EVERYTHING the device holds — `Note/`,
          # `Document/` and the rest of the firmware's folders — as real files on each
          # device-initiated sync, durable device-side deletes included. One direction only: books
          # go OUT by OPDS pull from Stump (#114/#115), so nothing is published through this tree.
          # Couples to the library tree (hosts/rk1/library.nix), which is why it lives behind its
          # own flag — see modules/nixos/profiles/supernote.nix.
          custom.profiles.supernote.mirror.enable = true;

          # Stump — the reading catalog over the document library (ADR-0031, #113). Indexes
          # /var/cache/library/{books,papers,notebooks} as three series-priority libraries (the
          # scan pattern is immutable, so it is set at creation by the provisioning oneshot) and
          # leaves the `_originals/` sibling unindexed by physical placement. Reads the tree as a
          # member of the `library` group; DB + thumbnails on the NVMe /var/cache/stump. Tailnet-
          # only, fronted by kelpy's Caddy at library.<domain> — DEPLOY KELPY TOO or the tailnet
          # gets a TLS error. See modules/nixos/profiles/stump.nix and the `library` entry in
          # parts/settings.nix; the pre-version-bump DB snapshot step is in the profile header.
          custom.profiles.stump.enable = true;

          # Book filer (#144): a 2-minute timer files EPUBs dropped in
          # /var/cache/books-inbox/<Subject>/ into /var/cache/library/books/<Subject>/, named
          # `<Title> - <Author>.epub` from the EPUB's own OPF metadata — no network lookup, the
          # good name is already in the file. The git-annex assistant adopts what appears in the
          # tree and Stump's watcher scans it in, so this is only the hop in between. Runs as
          # git-annex so filed books are library-owned; anything it cannot name is LEFT in the
          # inbox and counted in `books_inbox_stuck_files`. See
          # modules/nixos/profiles/book-filer.nix and docs/runbooks/book-filing.md.
          custom.profiles.book-filer.enable = true;

          # Off-host uptime watcher (Gatus): rk1b is always-on and not kelpy, so it
          # can observe kelpy failing. Probes the fleet + alerts to #infra-alerts.
          # See ADR-0019 / modules/nixos/profiles/monitoring/watcher.nix.
          # Monitoring server (moved from kelpy — kelpy's shared-disk write IO was
          # flagged as resource abuse; NVMe on rk1b absorbs it cleanly). VL/VM data
          # dirs redirect to /var/cache (NVMe) via BindPaths. See ADR-0021.
          custom.profiles.monitoring-server.enable = true;
          custom.profiles.monitoring-client.enable = true;
          # Off fleet-wide: DEFERRED, not blocked (palimpsest#150 — rsync.net is reachable;
          # this is a scheduling decision). reportJobs keeps the telemetry backup visible on
          # the Backups board as a disabled edge.
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
              # The media stack, moved here off kelpy (which watched these three before).
              "jellyfin.service"
              "podman-qbittorrent-app.service" # torrent
              "podman-slskd.service" # Soulseek music seeder (ADR-0029)
            ];
          };

          # Fleet disk-space watcher: rk1b already scrapes every node's node_filesystem_*
          # series, so one check here covers the whole fleet without keying the webhook
          # secret onto five more hosts. Thresholds come from each node's diskFloorGiB in
          # the fleet registry. Same webhook story as the checks above.
          custom.profiles.monitoring-disk-space = {
            enable = true;
            webhookUrlFile = config.custom.profiles.monitoring-watcher.webhookUrlFile;
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
