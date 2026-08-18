# The Supernote Private Cloud server (ADR-0031, palimpsest#92) — the device sync
# endpoint the Nomad binds via *Settings → Sync → Private Cloud*. A host-agnostic profile,
# enabled with `custom.profiles.supernote.enable = true` (rk1b, which shares the Nomad's
# home LAN 192.168.1.0/24). Packaged as `pkgs.supernote` (palimpsest#91).
#
# The server is UPSTREAM `allenporter/supernote`, pinned to an explicit rev (palimpsest#112
# retired the vendored fork this used to track — upstream implemented the device planner and
# realtime surface the fork existed to add). Six residual upstream gaps are filed rather than
# re-vendored: palimpsest#136 (delete/summary verb), #137 (planner writes), #138 (planner delete
# tombstones), #139 (planner batch), #140 (upload response path / rogue-root self-heal), and #142
# (concurrent logins for ONE account race a single-slot login challenge; the loser gets a
# misleading 401 "Invalid credentials"). #136-#139 are on the DEVICE's own sync, so a device
# banner after a rev bump is likely one of them; #140 is dormant on our store.
#
# #142 is the one that reaches THIS profile: the device and the mirror share one account (see
# the credential section) and the mirror is fired BY the device's sync, so their logins can
# collide. The mirror retries a 401 for exactly that reason — if you ever see it log
# "probably a lost login challenge", that is #142 and NOT a bad credential.
# Hardware acceptance is a manual pass: docs/runbooks/supernote-upstream-acceptance.md.
#
# ── The server carries the device's own content only (ADR-0031, palimpsest#117) ────────────
# Books reach the device by OPDS pull from Stump (palimpsest#114/#115), so nothing is injected into
# this store at all. #117 removed the outbound half accordingly — the one-shot outbox send, the
# last-synced baseline and the state they needed are gone, and the sweep below deletes what a
# pre-#117 deploy left behind. What remains is the DOWNWARD mirror: store → `library/supernote/`,
# the only path off the device for the pen layer.
#
# It mirrors the WHOLE device, not a chosen folder. It once mirrored only
# `/DOCUMENT/Document/ereader`, which was inherited from the retired push and turned out to mirror
# nothing at all: that folder existed only because the outbox created it, books now land in a
# folder Private Cloud never syncs, and the handwriting this server is kept for lives in `Note/`
# and `Document/`. Listing from the VFS root fixes that and needs no list of folders to maintain.
#
# The mirror is a STRICT materialisation: nothing is added to it locally, so a file it holds that
# the store does not is unambiguously a device-side delete. One guard, and no state behind it — if
# the store lists NO files at all while the mirror holds some, nothing is deleted. At whole-device
# scope an empty listing means the device's entire filesystem is empty, which is store loss rather
# than housekeeping; deleting one document among others still propagates immediately.
#
# Plain HTTP on the LAN — no TLS, no Caddy edge, no tailnet. The device is a locked-down
# Android tablet that can't run Tailscale, so it reaches rk1b directly on the LAN; that is
# why this service is NOT in `settings.services` (which is the Caddy-fronted, uptime-probed
# registry) and gets no vhost/monitor entry. The mirror (#107) reaches the store over
# this same HTTP API, never the filesystem, so the store below stays private.
#
# The server ALSO starts an MCP server (its LLM surface) on a second port — LLM features are
# out of v1, so that port is deliberately left OUT of the firewall allow-list (the server has
# no flag to disable it; it always binds `config.host`). Firewalling it off is what
# satisfies "do not expose the MCP port".
#
# ── The store (`/var/lib/supernote`) ─────────────────────────────────────────────────────
# One directory: the server's UUID blob store + SQLite VFS + cache. Owned by the private
# `supernote` user 0700 and — deliberately — NOT in the `library` group: the mirror
# reaches content over the client HTTP API, never the FS. Persisted WHOLE via impermanence +
# StateDirectory (ADR-0004 pattern). It is a strict, REBUILDABLE subset of the offsite-backed
# `library/` tree (hosts/rk1/library.nix), so — unlike `library/` — it has NO kelpy replica
# and NO offsite backup, and nothing here adds it to a restic path (restic is off fleet-wide
# on rk1b anyway; only the telemetry job is declared). Recovery if the store is lost:
#   • device intact → re-pair the Nomad to the server and let Private Cloud Sync re-seed it;
#   • device gone   → nothing re-seeds the store, and since #117 nothing can — there is no upload
#     path. The handwriting itself is not lost (`library/supernote/` holds it and IS backed up), but
#     it stays in the library rather than returning to a replacement device. Books are unaffected:
#     a new device pulls them from the catalog (#114/#115), never from here.
# Before bumping the `supernote` rev in flake.nix (which can alembic-migrate the DB), take a
# local `sqlite3 .backup` of /var/lib/supernote/system/supernote.db first (ADR-0031 consequence).
# The input is rev-pinned precisely so that migration is never an unattended `nix flake update`.
#
# ── The credential (one sops secret, shared with the mirror) ──────────────────────────────
# The Supernote account user (email) + password. The server binary itself reads no
# user/password env var; the credential's server-side consumer is the `supernote-account-bootstrap`
# oneshot below, which registers the single account (the server bootstraps the first user when
# the DB is empty, then locks registration) and proves login works. The SAME secret is what
# the device authenticates with and what the mirror's client logs in with — one account,
# no second auth surface. sops files are a separate repo (stash): create the secret, then
# `nix flake update secrets` here BEFORE deploy or activation fails (AGENTS.md gotcha).
#
# Lives in the shared `profiles/library.yaml` (this stack's secret bundle, shared with the
# mirror/#107) under a `supernote` sub-map:
#   supernote:
#     user: you@example.com        # the Supernote account — MUST be a valid email (the server
#     password: your-password      # validates EMAIL_REGEX on register)
# The file needs rk1b's host key as a recipient (sops is all-or-nothing per host) — its
# `.sops.yaml` creation rule must be `key_groups: [ age: [ *admin, *rk1b ] ]`.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  cfg = config.custom.profiles.supernote;

  # The device binds the sync endpoint here; the MCP port is the server's always-on LLM
  # surface, kept off the firewall (v1-out). Plain integers, not a settings.services entry
  # (this service is LAN-direct, not Caddy-fronted — see the header).
  port = 8080;
  mcpPort = 8081;

  stateDir = "/var/lib/supernote";
  localUrl = "http://127.0.0.1:${toString port}";
  # The credential lives in the shared library-stack bundle (profiles/library.yaml), under a
  # `supernote` sub-map — see the header. Shared with the mirror (#107).
  secretsFile = self.lib.getSecretFile "library";

  # ── The downward mirror (#107 as reduced by #117, widened to the whole device) ────────────
  mcfg = cfg.mirror;
  # `library/supernote/` materialises the WHOLE device store — every system folder the firmware
  # seeds (Note, Document, MyStyle, Export, Inbox, Screenshot), each appearing under the same
  # relative path the device uses. There is no remote path option and no per-folder list: the
  # mirror lists from the VFS root, so a folder the firmware adds later is picked up without a
  # change here.
  mirrorDir = "${mcfg.libraryPath}/supernote";

  # Paths this design has retired, swept on every start so a pre-existing deploy does not leave
  # them behind. All three sit where abandoning them costs something: the first two are inside the
  # BACKED-UP library tree, so an orphan would replicate to kelpy and go offsite forever, and the
  # third is persisted server state. Named rather than inlined so the sweep and this comment cannot
  # drift apart.
  #   • ereader-outbox/ — the one-shot send inbox, retired with the upload path (#117).
  #   • ereader/        — the old mirror root, when this mirrored ONLY /DOCUMENT/Document/ereader.
  #                       That folder was a vestige of the retired push (the outbox created it) and
  #                       nothing writes there: books arrive by OPDS into a folder Private Cloud
  #                       never syncs, and the handwriting lives in Note/ and Document/. It
  #                       mirrored nothing, so there is no content to migrate — only a dead
  #                       directory to remove.
  #   • reconcile/      — the last-synced baseline's directory, retired with the baseline (#117).
  retiredPaths = [
    "${mcfg.libraryPath}/ereader-outbox"
    "${mcfg.libraryPath}/ereader"
    "${stateDir}/reconcile"
  ];

  # A python interpreter with the `supernote` LIBRARY importable (the package is a
  # buildPythonApplication, so `toPythonModule` re-exposes its modules to withPackages). The
  # mirror drives `supernote.client` directly — client HTTP API only, never the server's FS store.
  mirrorPython = pkgs.python313.withPackages (ps: [ (ps.toPythonModule pkgs.supernote) ]);

  # Shared systemd hardening for the supernote units (server + mirror) — one source so
  # the two can't drift. Both only need outbound TCP + loopback, and both keep their writable state
  # under a systemd-managed dir (StateDirectory / RuntimeDirectory), so ProtectSystem=strict (whole
  # hierarchy read-only, reads intact) and ProtectHome (each unit's HOME is under /var/lib or /run,
  # never /home or /root) are both safe. The mirror unit additionally opens `library/supernote/`
  # via ReadWritePaths — the one path it writes, and the only path in the library tree it touches.
  hardening = {
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
    RestrictNamespaces = true;
    LockPersonality = true;
  };
in
{
  options.custom.profiles.supernote = {
    enable = lib.mkEnableOption "the Supernote Private Cloud server (device sync endpoint, ADR-0031)";

    # The downward mirror (ADR-0031, palimpsest#107 as reduced by #117) — off by default because it
    # couples to the git-annex `library` tree, which only exists on the media node (rk1b). The base
    # server profile above stays host-agnostic; a host with the library turns this on.
    mirror = {
      enable = lib.mkEnableOption "the downward mirror — materialise everything the device holds into library/supernote/ as real files, with durable device-side deletes, on each device-initiated sync (ADR-0031, palimpsest#117)";

      libraryPath = lib.mkOption {
        type = lib.types.str;
        default = "/var/cache/library";
        description = ''
          Root of the git-annex library tree (hosts/rk1/library.nix). Its `supernote/` subfolder is
          a strict downward mirror of everything the device holds — `Note/`, `Document/` and the
          other folders the firmware seeds, at the same relative paths — backed up and replicated,
          unlike the server store. Nothing is written into it by hand: there is no upload path, so
          a file here that the store lacks is treated as a device-side delete and removed. Books
          reach the device by OPDS pull from Stump, not through this tree.
        '';
      };

      group = lib.mkOption {
        type = lib.types.str;
        default = "library";
        description = ''
          Group owning the library tree (setgid, so writes stay group-readable). The `supernote`
          user joins it to read and write `supernote/`, which is created owned by this group.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        # A private, static system user. uid/gid are PINNED: the store lives on persisted disk,
        # and an auto-allocated id reshuffle across a reboot would orphan every blob/DB file in
        # place (this fleet has been bitten by exactly that — see [[kelpy-uid-map-drift]], and the
        # same reasoning openclaw/library pin theirs). 982 is free fleet-wide (977/978/981/987/993
        # gids and 985/988/989 uids are already taken; 982 is unclaimed).
        users.users.supernote = {
          isSystemUser = true;
          group = "supernote";
          uid = 982;
          home = stateDir;
          description = "Supernote Private Cloud server";
          # When the mirror is on, join the library group so it (running as this user) can read and
          # write library/supernote/ (setgid'd to `group`). Empty otherwise — the base server never
          # touches the library tree.
          extraGroups = lib.optional mcfg.enable mcfg.group;
        };
        users.groups.supernote.gid = 982;

        # The one shared credential, split into two scalar sops secrets from the `supernote` sub-map
        # of profiles/library.yaml (sops extracts scalars, not maps; the `a/b` key path descends
        # into the map). Owned by `supernote` so the service user — which runs both this server's
        # bootstrap oneshot and, later, the mirror (#107) — can read them.
        sops.secrets."supernote/user" = {
          sopsFile = secretsFile;
          key = "supernote/user";
          owner = "supernote";
        };
        sops.secrets."supernote/password" = {
          sopsFile = secretsFile;
          key = "supernote/password";
          owner = "supernote";
        };

        systemd.services.supernote-server = {
          description = "Supernote Private Cloud server (device sync endpoint)";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          # coreutils for the wrapper's `[`/`cat`; openssl mints the JWT key.
          path = [
            pkgs.coreutils
            pkgs.openssl
          ];
          environment = {
            # Bind all interfaces so the device reaches rk1b on the LAN; the firewall (below)
            # is what keeps the MCP port private. Storage under the StateDirectory.
            SUPERNOTE_HOST = "0.0.0.0";
            SUPERNOTE_PORT = toString port;
            SUPERNOTE_MCP_PORT = toString mcpPort;
            SUPERNOTE_STORAGE_DIR = stateDir;
            # Self-service registration stays disabled; the server still allows the FIRST user on an
            # empty DB (the bootstrap oneshot uses that), then this keeps it locked afterwards.
            SUPERNOTE_ENABLE_REGISTRATION = "false";
            # `supernote cloud login` (bootstrap + mirror) caches its token under $HOME/.cache;
            # point HOME at the persisted store so the cache survives reboots.
            HOME = stateDir;
          };
          serviceConfig = {
            User = "supernote";
            Group = "supernote";
            # Creates/owns /var/lib/supernote 0700; the server self-creates system/ + blob subdirs.
            StateDirectory = "supernote";
            StateDirectoryMode = "0700";
            WorkingDirectory = stateDir;

            # A stable JWT signing key so device + mirror access tokens survive a server
            # restart (the server otherwise generates a throwaway in-memory key each start, which
            # would invalidate the device's long-lived token on every deploy). Generated ONCE into
            # the persisted store — an auto-generated local infra key, not a credential, so the
            # "one secret / no second auth surface" invariant still holds. $STATE_DIRECTORY is set
            # by systemd from StateDirectory= above.
            ExecStart = pkgs.writeShellScript "supernote-server-start" ''
              set -euo pipefail
              jwt="$STATE_DIRECTORY/jwt-secret"
              if [ ! -s "$jwt" ]; then
                ( umask 077; openssl rand -hex 32 > "$jwt" )
              fi
              export SUPERNOTE_JWT_SECRET="$(cat "$jwt")"
              exec ${pkgs.supernote}/bin/supernote-server serve
            '';
            Restart = "on-failure";
            RestartSec = 5;
          }
          // hardening;
        };

        # Open ONLY the sync port. It goes on all interfaces (not scoped to `tailscale0` like the
        # tailnet services — the Nomad is LAN-only and can't run Tailscale, and rk1's physical NIC
        # isn't statically named here to scope to); the tailnet is trusted and every request is
        # login-gated, so the extra reach is harmless. The MCP port (${toString mcpPort}) is
        # deliberately absent — the server always binds it to the same host, so leaving it out of the
        # allow-list is what keeps the LLM surface off the network (v1-out).
        networking.firewall.allowedTCPPorts = [ port ];

        # Bootstrap the single account from the credential, and prove login works — the server's
        # side of "the secret is consumed by this server" and the "answers a login request" AC.
        # Idempotent: if login already succeeds the account exists and we stop; only an empty DB
        # takes the register path. A login failure right after a fresh register means a bad
        # credential and fails the unit LOUD (same spirit as navidrome/HA provisioners).
        systemd.services.supernote-account-bootstrap = {
          description = "Bootstrap the Supernote account from the credential secret and verify login";
          after = [
            "supernote-server.service"
            "sops-install-secrets.service"
          ];
          requires = [ "supernote-server.service" ];
          wants = [ "sops-install-secrets.service" ];
          wantedBy = [ "multi-user.target" ];
          path = [
            pkgs.coreutils
            pkgs.curl
          ];
          environment.HOME = stateDir;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "supernote";
            Group = "supernote";
            # Same StateDirectory as the server (for HOME/$STATE_DIRECTORY). Must repeat the 0700
            # mode: systemd re-applies StateDirectoryMode on every start, and its default (0755)
            # would otherwise loosen the server's 0700 store when this oneshot runs.
            StateDirectory = "supernote";
            StateDirectoryMode = "0700";
            # Credentials land in a private tmpfs (CREDENTIALS_DIRECTORY), never argv/environ.
            LoadCredential = [
              "user:${config.sops.secrets."supernote/user".path}"
              "password:${config.sops.secrets."supernote/password".path}"
            ];
            ExecStart = pkgs.writeShellScript "supernote-account-bootstrap" ''
              set -euo pipefail
              account="$(cat "$CREDENTIALS_DIRECTORY/user")"
              password="$(cat "$CREDENTIALS_DIRECTORY/password")"

              # Wait for the server to accept connections and finish DB migrations. /api/csrf is a
              # public GET that only answers once the app has started.
              for _ in $(seq 1 60); do
                if curl -sf -o /dev/null "${localUrl}/api/csrf"; then
                  break
                fi
                sleep 1
              done

              # Idempotent health/login proof: succeeds whenever the account already exists.
              #
              # Deliberately NOT retried, unlike the mirror (palimpsest#142). This probe is
              # exposed to the same lost-login-challenge race, and a collision here would send us
              # down the register path below, which then fails on an already-existing account —
              # a confusing deploy failure that reads like a bad secret. It is left alone anyway
              # because the cure is worse: every login attempt, failed ones included, counts
              # against upstream's per-account limit of 10 per 60s (server/utils/rate_limit.py,
              # checked BEFORE credentials are verified), so a retry loop here plus the
              # register+verify pair could trip a 429 on a FRESH install — trading a rare race for
              # a reliable one. The exposure is small (this runs at boot/deploy, not per sync),
              # and the mirror — which fires on EVERY device sync — is the hardened one.
              # If this unit fails with "Invalid credentials", re-run it before suspecting sops.
              if ${pkgs.supernote}/bin/supernote cloud login --url "${localUrl}" "$account" --password "$password"; then
                echo "supernote: account present, login OK"
                exit 0
              fi

              # Empty DB → register the single account (allowed only while no users exist), then
              # verify by logging in. `user add` posts the public registration; the login must then
              # succeed or a mis-set credential fails the unit here rather than silently at sync time.
              echo "supernote: no account yet — bootstrapping from the credential secret"
              ${pkgs.supernote}/bin/supernote admin --url "${localUrl}" user add "$account" --password "$password"
              ${pkgs.supernote}/bin/supernote cloud login --url "${localUrl}" "$account" --password "$password"
              echo "supernote: account bootstrapped, login OK"
            '';
          };
        };

        # Persist the store WHOLE across the tmpfs-root reboot (ADR-0004). Static user, so this
        # needs its own entry (unlike DynamicUser's /var/lib/private). No kelpy replica, no restic:
        # rebuildable subset of the offsite-backed library/ (see the header for recovery).
        environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
          directories = [
            {
              directory = stateDir;
              user = "supernote";
              group = "supernote";
              mode = "0700";
            }
          ];
        };

        # Enforce ADR-0031's "no offsite backup for the store" — the mirror of the library's
        # must-be-backed-up guard (hosts/kelpy/configuration.nix). The store is a rebuildable
        # subset of the offsite-backed library/, so a restic job must never sweep it up. Comments
        # can't stop a future broad path; this fails the build the moment any restic `paths` entry
        # becomes an ancestor of the store (live or persisted). Lazy-safe: with no backups declared,
        # attrValues is [] and the assertion is trivially true.
        assertions =
          let
            storePaths = [
              stateDir
              "/persistent${stateDir}"
            ];
            resticPaths = lib.concatMap (b: b.paths or [ ]) (lib.attrValues config.services.restic.backups);
            covers = rp: lib.any (sp: sp == rp || lib.hasPrefix "${rp}/" sp) storePaths;
          in
          [
            {
              assertion = !lib.any covers resticPaths;
              message = "custom.profiles.supernote: a restic backup now covers the server store (${stateDir}), but ADR-0031 keeps it OUT of any offsite backup (it is a rebuildable subset of the offsite-backed library/). Remove that path or narrow the backup.";
            }
          ];
      }

      # ── The downward mirror (ADR-0031, palimpsest#107 as reduced by #117) ──────────────────
      (lib.mkIf mcfg.enable {
        # Make library/supernote/ exist: group-writable + setgid, owned by the tree owner
        # (git-annex, like the rest of the library) so the mirror (supernote user, via the library
        # group) can write it and git-annex can adopt what it writes. 2770 not 2775 — the tree is
        # not world-readable. A oneshot rather than a tmpfiles rule so it can wait for the
        # /var/cache NVMe mount — the git-annex module avoids a plain tmpfiles rule here for exactly
        # that mount-race reason. `install -d` is idempotent and applies the same owner/group/mode
        # git-annex would, so ordering against git-annex-init is immaterial (both converge).
        #
        # The same oneshot sweeps the retired paths (see `retiredPaths`), because all of them
        # outlive a deploy and two sit inside the git-annex tree, where an orphan replicates to
        # kelpy and goes offsite forever. `rm -rf` rather than a tmpfiles `R` rule for the same
        # mount-race reason, and because it must run BEFORE the mirror can be fired. Destructive by
        # intent, and it says what it removed: nothing it deletes has a live writer any more.
        systemd.services.supernote-mirror-dir = {
          description = "Ensure library/supernote/ exists (group-writable, setgid) and sweep the retired paths";
          wantedBy = [ "multi-user.target" ];
          unitConfig.RequiresMountsFor = [ mcfg.libraryPath ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = pkgs.writeShellScript "supernote-mirror-dir" ''
              set -euo pipefail
              ${pkgs.coreutils}/bin/install -d -o git-annex -g ${mcfg.group} -m 2770 ${mirrorDir}

              # Say what is being removed rather than removing it silently, so a deploy that
              # discards something leaves a trace in the journal.
              for retired in ${lib.concatStringsSep " " retiredPaths}; do
                if [ -e "$retired" ]; then
                  echo "supernote mirror: removing retired path $retired, containing:"
                  ${pkgs.coreutils}/bin/ls -A "$retired" || true
                  ${pkgs.coreutils}/bin/rm -rf "$retired"
                fi
              done
            '';
          };
        };

        # The mirror oneshot — fired by the watcher on each device-initiated sync, never on a
        # timer. Logs in with the shared credential and materialises everything the device holds
        # into library/supernote/, propagating device-side deletes. Client HTTP API only; it never
        # touches the server's FS store — note there is no StateDirectory here, so the sandbox does
        # not even make the store writable to it. Trigger-only: no wantedBy, so it runs solely when
        # the watcher `systemctl start`s it.
        systemd.services.supernote-mirror = {
          description = "Mirror the Supernote device down into library/supernote/ (palimpsest#117)";
          after = [
            "supernote-server.service"
            "supernote-mirror-dir.service"
          ];
          requires = [
            "supernote-server.service"
            "supernote-mirror-dir.service"
          ];
          # Wait for the NVMe library mount too — ReadWritePaths below binds paths under it, which
          # fails the namespace setup if the mount is not yet up.
          unitConfig.RequiresMountsFor = [ mcfg.libraryPath ];
          environment = {
            SUPERNOTE_URL = localUrl;
            MIRROR_DIR = mirrorDir;
            # A writable HOME under the unit's private runtime dir (some libs consult $HOME); the
            # mirror itself caches nothing else — it logs in fresh each run.
            HOME = "/run/supernote-mirror";
          };
          serviceConfig = {
            Type = "oneshot";
            User = "supernote";
            Group = "supernote";
            RuntimeDirectory = "supernote-mirror";
            RuntimeDirectoryMode = "0700";
            # It downloads into supernote/, so that one path is writable under
            # ProtectSystem=strict; everything else — including the server store — stays read-only.
            # (Before #117 this unit also carried StateDirectory=supernote, to persist the baseline
            # inside the store. With the baseline gone the declaration went with it, which is what
            # makes "the store is reached only over the client API" true of the sandbox and not just
            # of the code.)
            ReadWritePaths = [ mirrorDir ];
            # Downloaded files must be group-writable (0664) so git-annex (in the library group) can
            # manage/replicate/drop them — the same reach beets has into the music tree (ADR-0028).
            UMask = "0002";
            # Credentials land in a private tmpfs (CREDENTIALS_DIRECTORY), never argv/environ — same
            # shape as the server bootstrap; the same one account, no second auth surface.
            LoadCredential = [
              "user:${config.sops.secrets."supernote/user".path}"
              "password:${config.sops.secrets."supernote/password".path}"
            ];
            ExecStart = pkgs.writeShellScript "supernote-mirror-start" ''
              set -euo pipefail
              export SUPERNOTE_USER_FILE="$CREDENTIALS_DIRECTORY/user"
              export SUPERNOTE_PASSWORD_FILE="$CREDENTIALS_DIRECTORY/password"
              exec ${mirrorPython}/bin/python ${./supernote-mirror.py}
            '';
          }
          // hardening;
        };

        # The sync-coupled trigger: NOT a timer and NOT a file-watcher (the owner constraint,
        # carried over from #94, and unchanged by #117 — reducing the sync removed a direction, not
        # the trigger). It follows the server's journal and fires the reconcile the
        # moment the device opens a sync — POST /api/file/2/files/synchronous/start, which the
        # server's aiohttp access log records (%r request line). Debounced so a burst of starts
        # coalesces into one run. Runs as root: it reads the server unit's journal and
        # `systemctl start`s the mirror. On restart it follows from the tail (-n0), so historical
        # sync lines are never replayed.
        systemd.services.supernote-mirror-watch = {
          description = "Fire the mirror when the Supernote starts a sync (palimpsest#107)";
          wantedBy = [ "multi-user.target" ];
          after = [ "supernote-server.service" ];
          wants = [ "supernote-server.service" ];
          serviceConfig = {
            Restart = "always";
            RestartSec = 5;
            ExecStart = pkgs.writeShellScript "supernote-mirror-watch-start" ''
              set -eu
              last=0
              debounce=15
              ${pkgs.systemd}/bin/journalctl -u supernote-server.service -f -n0 -o cat \
                | while IFS= read -r line; do
                    case "$line" in
                      *synchronous/start*)
                        now=$(${pkgs.coreutils}/bin/date +%s)
                        if [ $((now - last)) -ge "$debounce" ]; then
                          last=$now
                          echo "supernote mirror watch: device sync detected, firing the mirror"
                          # Keep the follower alive even if the enqueue momentarily fails (set -e
                          # would otherwise tear down the pipeline and bounce the whole watcher) —
                          # but SAY SO. Swallowing it silently left the line above asserting an
                          # action that may not have happened, which is the same defect the
                          # mirror's `store=` token fixes: a log that reads as informative
                          # while carrying no information. A dropped trigger is invisible from the
                          # reconcile unit's own journal (it simply has one fewer run), so this
                          # line is the only place it could ever surface.
                          if ! ${pkgs.systemd}/bin/systemctl start --no-block supernote-mirror.service; then
                            echo "supernote mirror watch: FAILED to enqueue the mirror — this sync will NOT be mirrored; the next sync retries"
                          fi
                        fi
                        ;;
                    esac
                  done
            '';
          };
        };
      })
    ]
  );
}
