{
  config,
  inputs,
  lib,
  pkgs,
  self,
  settings,
  ...
}:
{
  imports = [
    inputs.vpsFree.nixosModules.containerUnstable

    self.nixosProfiles.bundle

    ./git-annex.nix
  ];

  custom.profiles = {
    base.enable = true;
    impermanence.enable = true;
    tailscale = {
      enable = true;
      tags = [ "tag:server" ];
    };
    ssh.enable = true;
    # Deliberately NOT passwordless sudo: kelpy is the public-facing VPS, so keep
    # the sudo password as defense-in-depth. `just deploy kelpy` supplies it via
    # --ask-sudo-password (prompted once, up front).
    proxy.enable = true;
    # DEFERRED, not blocked — the reason this is off is a scheduling decision, not an
    # obstacle. The older note here said rsync.net was unreachable and held a stale
    # exclusive lock from stargazer; both halves have decayed:
    #   • zh2046.rsync.net is REACHABLE — TCP 22 connects from this host (checked
    #     2026-08-19). "Unreachable" has not been true for some time.
    #   • stargazer no longer configures backup at all, so nothing there can still be
    #     taking a lock. Whether the repo carries a leftover one is untested, and is only
    #     testable by running restic.
    # Turning this on is what ships the document library replica offsite (see the paths /
    # exclude / assertion below — the wiring is already correct and needs no path change).
    # Tracked in palimpsest#150, which carries the fleet-wide picture and the open
    # questions. Until then the library lives on two git-annex replicas and nowhere else.
    backup.enable = false;
    # Still surface this host's off-site job on the Backups board — as a known-off edge.
    backup.reportJobs = [ "daily" ];
    monitoring-server.enable = false; # moved to rk1b (ADR-0021)
    monitoring-client.enable = true;
    monitoring-dmarc.enable = false;
    # On-host white-box layer for ADR-0019: alerts to #infra-alerts (via the
    # hookshot loopback webhook) when a long-running daemon stops being active —
    # complements the off-host Gatus reachability probe on rk1b. The unit list is
    # CURATED (these names are kelpy-specific); add/remove as services change.
    # affine is intentionally omitted (it currently has no unit on kelpy).
    monitoring-unit-state = {
      enable = true;
      units = [
        "caddy.service" # the edge — everything web-facing depends on it
        "blocky.service" # fleet DNS
        "stalwart.service" # mail
        "tuwunel.service" # matrix homeserver
        "matrix-hookshot.service" # the alert delivery path itself
        # music-sync.service is deliberately NOT listed: it is a oneshot (path/timer
        # triggered), so it is `inactive` by design between runs and this active-watch
        # would spam. A failed drain surfaces via its systemd unit-state metric + the
        # backstop timer's retry; a dedicated OnFailure alert is a possible follow-up.
        "vector.service" # monitoring-client still runs here; server moved to rk1b
        # The private forge (palimpsest#212). This is the alerting half of the memory
        # fence: a one-off OOM kill is absorbed by `Restart = always` and shows up only as
        # the cgroup `oom_kill` counter, but a genuine runaway crash-loops past the start
        # limit into `failed` — which is exactly what this watch sees.
        "forgejo.service"
        # The vault (users#39). Same alerting half of the same memory fence as the forge —
        # and the stakes are higher: every credential this home reads goes through `rbw`,
        # whose reads work offline from a cache, so a dead vault is INVISIBLE to the operator
        # until the first write or the first uncached lookup. The off-host Gatus probe covers
        # the vhost; this covers the unit.
        "vaultwarden.service"
        "paperless-scheduler.service"
        "paperless-task-queue.service"
        "paperless-consumer.service"
      ];
    };
    # Daily secret-expiry watcher (ADR-0024): reads the plaintext expiry registry
    # (secrets/expiry.nix) and alerts #infra-alerts before a rotatable secret (e.g.
    # the 90-day tailscale auth key) lapses. Reuses the infraAlerts webhook + the
    # node-exporter textfile metric for a Grafana "days remaining" gauge.
    monitoring-secret-expiry.enable = true;
    # git-annex replication watcher (palimpsest#60): a git-annex repo that stops
    # replicating reports healthy in every other way, so nothing else here can see it.
    # Uses the infraAlerts webhook by default, like the checks above.
    #
    # This covers the `music` replica (assistant + remote → rk1b). It does NOT
    # meaningfully cover `pictures`: that repo is passive — no assistant, no remotes,
    # the desktop's home-manager client pushes INTO it — so the only signal available
    # on this side is whether the check itself still runs. Watching the photo link
    # properly means teaching the home-manager module to export too, which is where
    # that repo's outbound half actually lives. Not done here.
    monitoring-git-annex-alert.enable = true;
    # Per-unit cgroup memory metrics (palimpsest#211). The fleet's only memory
    # instrumentation, landed in the same deploy as its first memory cap because a
    # measurement that arrives after the thing it measures has a hole exactly where the
    # interesting data is. Collection only — no alert, because there is no baseline yet and
    # any threshold would be invented.
    #
    # The list is the newcomer PLUS the incumbents it now shares 4 GB with, so the numbers
    # are comparable and #215's tighten-the-cap step has something to compare against.
    # caddy is included as the control: it is the busiest unit here and the least likely to
    # surprise, so an odd reading on it means the metric is wrong, not the service.
    monitoring-cgroup-memory = {
      enable = true;
      units = [
        "forgejo.service" # the capped unit — the reason this module exists
        # The vault's cap is provisional in exactly the way the forge's is, and for the same
        # reason: no trustworthy footprint figure, so it is sized by what the host can spare.
        # This series is what the tighten step reads — note the floor, though: verifying the
        # /admin token runs Argon2id at m=64 MiB, so a cap near idle would OOM every login.
        "vaultwarden.service"
        "tuwunel.service" # matrix homeserver; an OOM casualty in the immich incident
        "stalwart.service" # mail
        "caddy.service" # the edge, and the control series
        "paperless-task-queue.service" # the other memory-hungry incumbent
      ];
    };
    # The private forge (palimpsest#204 / #212) — Forgejo, tailnet-only, for NEW private
    # projects. Co-located with the Caddy edge, so it listens on loopback; only its
    # git-over-SSH port is opened, on tailscale0.
    #
    # ⚠ It is MEMORY-CAPPED (MemoryMax = 1G) and that cap is provisional — no trustworthy
    # Forgejo footprint figure exists, so it is sized by what this host can spare rather
    # than by what Forgejo needs. palimpsest#215 carries the measure-and-tighten step; the
    # cgroup-memory metric above is what it reads. If an `oom_kill` shows up, the answer is
    # to RAISE the cap, not to move the forge — the move to rk1b triggers only when the
    # raise would push kelpy below 1 GB available.
    forge.enable = true;
    # The vault (users#32 / users#39) — Vaultwarden, tailnet-only, single-account, SQLite.
    # kelpy and not rk1b, decided on users#37: it is co-located with the forge, carries no
    # `origin`, and `caddyEdges = [ "kelpy" ]` already puts this host in the request path
    # whichever machine serves — so rk1b would add a machine in series for no availability
    # gain. State lands under /persistent, which this host's restic job already declares (and
    # which is merely switched off above).
    #
    # ⚠ It is MEMORY-CAPPED (MemoryMax = 512M), provisional for the same reason the forge's
    # is. Read the profile's `memoryMax` description before changing it: the floor is set by
    # Argon2id at m=64 MiB on every /admin login, not by the idle footprint.
    #
    # ⚠ Reads from this vault are RELIED ON while it is down, not merely tolerated (users#37):
    # `rbw`'s offline cache has no TTL, so consumers keep working — which is also why a dead
    # vault is quiet, and why vaultwarden.service is in the unit-state watch above.
    vaultwarden.enable = true;
    # Immich is NOT enabled here. It lives on rk1b (see hosts/default.nix and the
    # `immich` entry in parts/settings.nix); kelpy only fronts it with Caddy.
    # It ran here briefly and could not: 4G, no swap, and immich-server peaks
    # ~1.4G importing geodata on first start, so it OOM-looped and the kernel
    # killed tuwunel and jellyfin alongside it. Do not re-enable it on this host
    # without giving kelpy considerably more memory.
    mail = {
      enable = true;
      inherit (settings.mail) domain extraDomains;
    };
    # Auto-reconcile the mail domains' DANE/TLSA records when acme renews the mail cert,
    # so the published TLSA never drifts from the served cert (mail-scoped dns push).
    mail-dane-autoupdate.enable = true;
    # Tag mail that reaches this mailbox by Gmail forwarding, so the origin of
    # every message stays answerable after the Gmail cutover
    # (docs/runbooks/gmail-to-stalwart.md).
    mail-sieve = {
      enable = true;
      user = "thomas";
      script = ''
        require ["imap4flags", "fileinto"];

        # Gmail sets X-Forwarded-For on everything it forwards from the old
        # account. File those into the same mailbox the one-off archive import
        # filled, and tag them with the same keyword, so everything that ever
        # arrived via the old Gmail address lives in one place. The tagged
        # proportion is the cutover's real progress metric: it falls as
        # correspondents are updated, and reaching zero is when Gmail can be
        # retired.
        #
        # fileinto, not just the keyword, because the keyword alone is not
        # portable across clients: an IMAP keyword is invisible in any client
        # without a local tag definition for it (Thunderbird ignores unknown
        # keywords outright), whereas a mailbox renders everywhere with no
        # client-side config. The keyword is kept as metadata for searching.
        #
        # fileinto CANCELS Sieve's implicit keep, so these messages land only in
        # the Gmail mailbox and never in the Inbox. That is the intent — watch
        # that mailbox's unread count, not the Inbox, for forwarded mail.
        #
        # jmap-bridge is unaffected: live sync polls Email/changes, which is
        # account-wide and not scoped to a mailbox, so these still reach Matrix.
        # Verified — the post-reset backfill processed 39 messages already in
        # this mailbox, and a live forward minted its room two seconds after
        # delivery.
        #
        # Deliberately does NOT set $seen. Forwarded mail is new mail and must
        # arrive unread; the archive's blanket $seen was a one-off for history,
        # not a delivery policy.
        if header :contains "X-Forwarded-For" "tsdkelly@gmail.com" {
            addflag "gmail:tsdkelly";
            fileinto "Gmail";
        }
      '';
    };
    matrix = {
      enable = true;
      whatsapp.enable = true;
      jmap-bridge.enable = true;
      hookshot = {
        enable = true;
        # Keep the personal GitHub notification feed out of the @hookshot admin DM
        # and in its own room, so the DM stays a command surface. `github login`
        # (per-user OAuth) is still run by hand, once, in the DM.
        notificationsRoom.enable = true;
        # `github login` cannot drive the notification feed: GET /notifications
        # rejects GitHub App tokens outright and only takes a classic PAT. Store one
        # from sops rather than pasting it into the (unencrypted) admin DM. Reuses
        # the fleet `github_token` declared by nixConfig.nix — classic, `repo` scope,
        # which is what makes private-repo notifications render.
        personalToken = {
          enable = true;
          secretName = "github_token";
        };
      };
      # The room id is no longer a build-time input: the connection is provisioned
      # into room state at runtime, so the oneshot creates the room and persists
      # its id. The previously pinned id was wiped by a July matrix-reset and had
      # been dead for weeks, which is precisely the failure mode that removed it.
      infraAlerts.enable = true;
    };
    paperless.enable = true;
    blocky.enable = true;
    # custom.profiles.media is NOT enabled here. The whole stack — gluetun, qBittorrent,
    # slskd and Jellyfin — moved to rk1b (hosts/default.nix): memory relief on a 4G host,
    # and the torrent write IO belongs on rk1b's NVMe rather than this shared VPS disk
    # (the resource-abuse flag that already moved monitoring, ADR-0021). kelpy keeps only
    # the Caddy vhosts.
  };

  # kelpy is internet-facing (public Caddy edge, a federated homeserver) and runs services
  # that reach out on the operator's behalf. Set originally for the Claude relay's
  # code-executing `claude` sessions (ADR-0018, since removed); kept because the posture is
  # the host's, not that one service's.
  #
  # IT ENFORCES NOTHING. The note that used to sit here claimed the contract "refuses any
  # secret-bearing user-feature grant" on an exposed host; it does not, and never did. The
  # pinned contract says so in as many words — modules.nix:72 calls `exposed` "a plain fact
  # a host operator records; the contract enforces nothing on it", and features.nix:10 reads
  # "A feature never carries a secret (ADR-0003)", so there is no such grant to refuse in the
  # first place. This flag is a posture RECORD: something a human reads when deciding what
  # belongs here. Corrected while wiring the forge (palimpsest#212), whose token placement
  # question (#209) was framed around the enforcement this comment invented.
  contract.exposed = true;

  # systemd implements IP accounting by attaching a cgroup BPF program to every unit, and
  # kelpy — a vpsAdminOS container — is not permitted to attach them. So each unit start
  # emits:
  #
  #   <unit>: bpf-firewall: Attaching egress BPF program to cgroup
  #     /sys/fs/cgroup/system.slice/<unit> failed: Invalid argument
  #
  # which cost 10,337 journal lines in two days here (~5k/day), concentrated on the
  # timer-driven checks that start every 60s. That matters more now the journal is capped
  # (profiles/base.nix), because this noise evicts real history.
  #
  # Turning it off loses nothing, because the accounting is ALREADY dead on this host: the
  # attach fails, so the counters never move. Measured — `caddy`, which fronts the whole
  # fleet's web traffic, reports IPIngressBytes=0 and IPEgressBytes=0 here, while the same
  # counters on rk1b (bare metal, where the attach succeeds) read 33 MB in / 730 MB out for
  # grafana alone. Nothing in this repo consumes the counters either way.
  #
  # Deliberately host-scoped, NOT fleet-wide: on every other host the attach works, the
  # numbers are real, and there is no noise to silence. The failure is a property of the
  # container, not of the setting.
  systemd.settings.Manager.DefaultIPAccounting = false;
  # NOTE: signing is intentionally NOT granted here. It is now a home-sops feature
  # (contract ADR-0002, slice 13) decryptable only by the user's own key, which a headless
  # agent host lacks — and the agent should not sign commits as inkpotmonkey anyway.

  networking = {
    inherit (settings.nodes.kelpy) hostName domain;
  };

  # WHAT this host backs up — ENUMERATED, not a machine snapshot (ADR-0036).
  #
  # kelpy holds more irreplaceable state than anything else on the fleet: the mail store that
  # replaces Gmail, the credential store, scanned paper, the forge, the Matrix homeserver and
  # its bridges, and two git-annex replicas. It also holds a few hundred megabytes of logs,
  # caches and agent checkouts, and the old `paths = [ "/persistent" ]` shipped all of it
  # off-site every night — inflating every snapshot, defeating restic's dedup on the churning
  # parts, and burying the question of what actually matters.
  #
  # `classifyPersistence` makes that question compulsory rather than optional: every directory
  # impermanence keeps must appear below, either in `paths` or in `notBackedUp` with a reason.
  # Add a service that persists state and the build FAILS until someone decides. That is the
  # one real weakness of enumerating — silently missing a new service — closed.
  #
  # Paths name the BACKING STORE (/persistent/...) rather than the bind-mounted view, which is
  # the same bytes without traversing a bind mount, and is what the ADR-0031 guard below
  # already assumes.
  custom.profiles.backup.jobs.daily = {
    classifyPersistence = "/persistent";

    paths = [
      # ── The things that exist nowhere else ──────────────────────────────────────────────
      # Mail. Once the Google account is emptied this is the ONLY copy of the archive, and
      # Stalwart keeps messages, folders and credentials here together.
      "/persistent/var/lib/stalwart-mail"
      # The fleet's credential store. Losing it locks us out of everything it holds, and
      # nothing else has a copy — by design.
      "/persistent/var/lib/vaultwarden"
      # Scanned paper. The point of scanning it was to throw the paper away.
      "/persistent/var/lib/paperless"
      # The forge. Some repositories here have no GitHub remote, so a push is not a backup.
      "/persistent/var/lib/forgejo"
      # Both git-annex replicas, and both qualify for different reasons: `library` is the
      # Supernote document library that ADR-0031/#90 requires off-site, and `pictures` is the
      # passive replica of the workstation's ~/Pictures — personal photos whose only other
      # copy is that workstation. A replica is not a backup: two live copies both follow a
      # delete. (Whether the pictures annex and the Immich library should converge is open —
      # see ADR-0034 and CONTEXT.md. Until it is settled, this tree is backed up.)
      "/persistent/var/lib/git-annex"

      # ── Matrix: the homeserver and the bridge identities ────────────────────────────────
      # Rooms, message history and device keys. Re-creating the homeserver loses the history
      # and every device verification with it.
      "/persistent/var/lib/private/tuwunel"
      # WhatsApp bridge session: losing it means re-pairing the phone by QR code.
      "/persistent/var/lib/mautrix-whatsapp"
      "/persistent/var/lib/private/matrix-dm-whatsapp"
      "/persistent/var/lib/private/jmap-bridge"
      # Bridge state and the room/space IDs the alerting wiring points at. Kilobytes each,
      # and regenerating them means re-creating rooms by hand and re-pointing webhooks — the
      # cheapest entries here by far and among the most tedious to lose.
      "/persistent/var/lib/matrix-hookshot"
      "/persistent/var/lib/private/matrix-dm-hookshot"
      "/persistent/var/lib/matrix-hookshot-adminroom"
      "/persistent/var/lib/private/matrix-hookshot-space"
      "/persistent/var/lib/matrix-hookshot-notifications-adminroom"
      "/persistent/var/lib/matrix-hookshot-notifications-room"
      "/persistent/var/lib/matrix-hookshot-github-token"
      "/persistent/var/lib/matrix-infra-alerts"

      # ── Small, load-bearing on the way back ─────────────────────────────────────────────
      # The uid/gid map. Tiny, and without it a rebuilt host can assign different numbers to
      # the same names — at which point every restored file is owned by the wrong service.
      # This is the entry most likely to be dismissed as uninteresting and most likely to
      # make a restore hurt.
      "/persistent/var/lib/nixos"
      # The ACME account key. Certificates re-issue on their own; the ACME ACCOUNT does not,
      # and re-registering under rate limits during an outage is a bad time to find out.
      "/persistent/var/lib/acme"
      # The relay agent's accumulated session history and memory. 20M, and the only record of
      # what the agent has been asked and has learned; the credentials beside it re-auth.
      "/persistent/home/inkpotmonkey/.claude"
    ];

    # Everything impermanence keeps that is deliberately NOT shipped off-site. The reason is
    # the point: "we decided" has to be distinguishable from "we forgot", and a stale entry
    # here fails the build so the list keeps describing the machine that exists.
    notBackedUp = {
      "/var/log" =
        "logs churn every night, so they both inflate each snapshot and defeat restic's dedup — and no restore anyone wants starts by recovering last week's journal";
      "/var/cache/private" = "a cache; rebuilt by whatever filled it";
      "/var/lib/redis-paperless" =
        "paperless's redis is a work queue and a cache, rebuilt on start from the postgres state that IS backed up";
      "/var/lib/caddy" =
        "certificates re-issue automatically over DNS-01, and nothing else here survives a restore usefully";
      "/var/lib/tailscale" =
        "a node identity, re-authed in one command — and better rotated than restored after an incident";
      "/etc/nixos" = "the flake is this repository: in git, pushed, and on every other host";
      "/home/inkpotmonkey/code" =
        "the agent's working copies of repositories that live in git and are pushed; 359M of re-clonable checkouts. Uncommitted work here is NOT protected, which is an argument for committing, not for a bigger backup";
    };

    # The music and slskd-downloads excludes that used to sit here are GONE with the data:
    # custom.profiles.media and the `music` git-annex replica both moved to rk1b, so neither
    # path exists on this host any more and excluding them would be dead config. Enumerating
    # `paths` makes most excludes unnecessary anyway — you cannot exclude what you never
    # named. The `library` replica is deliberately INCLUDED above; see the assertion below.
    exclude = [ ];
  };

  # Enforce the ADR-0031/#90 divergence from music: the document library replica MUST go
  # offsite, so no restic exclude may cover it. The comments above can't stop a future edit
  # widening the music exclusion to /var/lib/git-annex; this fails the build the moment such
  # an exclude covers the library.
  #
  # It now reads the JOB rather than `services.restic.backups.daily.exclude`, which makes it
  # ALWAYS LIVE: the old form had to be guarded with `!backup.enable ||` because the restic
  # entry did not exist while backups were deferred, so the guard was dormant for the whole
  # time it mattered most — someone could have widened the exclude and the build would have
  # passed. The job's `exclude` exists whether or not the job runs, so the guard does too.
  assertions = [
    {
      assertion =
        !lib.any (
          e: lib.hasPrefix e "/persistent/var/lib/git-annex/library"
        ) config.custom.profiles.backup.jobs.daily.exclude;
      message = "hosts/kelpy: a restic exclude now covers the Supernote document library replica (/persistent/var/lib/git-annex/library), but ADR-0031/#90 requires it backed up offsite. Do not widen the music exclusion to /var/lib/git-annex.";
    }
  ];

  # Persist the agent's home state across impermanence reboots: Claude Code
  # subscription credentials/config and the project checkouts the relay's sessions
  # work in.
  environment.persistence."/persistent".users.inkpotmonkey.directories = [
    ".claude"
    "code"
  ];

  nixpkgs = {
    hostPlatform = "x86_64-linux";
  };

  environment.systemPackages = with pkgs; [
    git
  ];

  system.stateVersion = "25.11";
}
