# The Supernote Private Cloud server (ADR-0031, palimpsest#92) — the device sync
# endpoint the Nomad binds via *Settings → Sync → Private Cloud*. A host-agnostic profile,
# enabled with `custom.profiles.supernote.enable = true` (rk1b, which shares the Nomad's
# home LAN 192.168.1.0/24). Packaged as `pkgs.supernote` (palimpsest#91).
#
# The server is UPSTREAM `allenporter/supernote`, pinned to an explicit rev (palimpsest#112
# retired the vendored fork this used to track — upstream implemented the device planner and
# realtime surface the fork existed to add). Four residual upstream gaps are filed rather than
# re-vendored: palimpsest#136 (delete/summary verb), #137 (planner writes), #138 (planner delete
# tombstones), #139 (planner batch). None is on the document path this profile drives, but all
# four are on the DEVICE's own sync — so a device banner after a rev bump is likely one of them.
# Hardware acceptance is a manual pass: docs/runbooks/supernote-upstream-acceptance.md.
#
# Plain HTTP on the LAN — no TLS, no Caddy edge, no tailnet. The device is a locked-down
# Android tablet that can't run Tailscale, so it reaches rk1b directly on the LAN; that is
# why this service is NOT in `settings.services` (which is the Caddy-fronted, uptime-probed
# registry) and gets no vhost/monitor entry. The reconciler (#107) reaches the store over
# this same HTTP API, never the filesystem, so the store below stays private.
#
# The server ALSO starts an MCP server (its LLM surface) on a second port — LLM features are
# out of v1, so that port is deliberately left OUT of the firewall allow-list (the server has
# no flag to disable it; it always binds `config.host`). Firewalling it off is what
# satisfies "do not expose the MCP port".
#
# ── The store (`/var/lib/supernote`) ─────────────────────────────────────────────────────
# One directory: the server's UUID blob store + SQLite VFS + cache. Owned by the private
# `supernote` user 0700 and — deliberately — NOT in the `library` group: the reconciler
# reaches content over the client HTTP API, never the FS. Persisted WHOLE via impermanence +
# StateDirectory (ADR-0004 pattern). It is a strict, REBUILDABLE subset of the offsite-backed
# `library/` tree (hosts/rk1/library.nix), so — unlike `library/` — it has NO kelpy replica
# and NO offsite backup, and nothing here adds it to a restic path (restic is off fleet-wide
# on rk1b anyway; only the telemetry job is declared). Recovery if the store is lost:
#   • device intact  → re-pair the Nomad to the server and let Private Cloud Sync re-seed it;
#   • device gone     → re-send the books from `library/ereader/` via the one-shot outbox (#107).
# Before bumping the `supernote` rev in flake.nix (which can alembic-migrate the DB), take a
# local `sqlite3 .backup` of /var/lib/supernote/system/supernote.db first (ADR-0031 consequence).
# The input is rev-pinned precisely so that migration is never an unattended `nix flake update`.
#
# ── The credential (one sops secret, shared with the reconciler) ──────────────────────────
# The Supernote account user (email) + password. The server binary itself reads no
# user/password env var; the credential's server-side consumer is the `supernote-account-bootstrap`
# oneshot below, which registers the single account (the server bootstraps the first user when
# the DB is empty, then locks registration) and proves login works. The SAME secret is what
# the device authenticates with and what the reconciler's client logs in with — one account,
# no second auth surface. sops files are a separate repo (stash): create the secret, then
# `nix flake update secrets` here BEFORE deploy or activation fails (AGENTS.md gotcha).
#
# Lives in the shared `profiles/library.yaml` (this stack's secret bundle, shared with the
# reconciler/#107) under a `supernote` sub-map:
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
  # `supernote` sub-map — see the header. Shared with the reconciler (#107).
  secretsFile = self.lib.getSecretFile "library";

  # ── The ereader round-trip (#107, superseding #94) ────────────────────────────────────────
  ecfg = cfg.ereader;
  # `library/ereader/` is the DOWNWARD MIRROR of the store's ereader folder; `library/ereader-outbox/`
  # is the one-shot send inbox (drop a book there to publish it once). The device shows documents
  # under /DOCUMENT/Document (the firmware's two-level doc root, seeded per-account by the server —
  # supernote/server/services/user.py); the trailing `ereader/` is auto-created by the server on
  # first upload. A constant, not an option — the device's doc root is fixed firmware.
  ereaderLocalDir = "${ecfg.libraryPath}/ereader";
  ereaderOutboxDir = "${ecfg.libraryPath}/ereader-outbox";
  ereaderRemoteDir = "/DOCUMENT/Document/ereader";
  # The last-synced baseline (previous store snapshot, `{rel: md5}`) — the minimal state that lets
  # the reconciler tell a device-side delete from a fresh local add. It lives INSIDE the server store
  # dir on purpose: the store is rebuildable and un-backed-up, so co-locating the baseline makes it
  # share the store's fate — a wiped store loses the baseline too, which is exactly the signal the
  # store-loss guard needs (empty store + no baseline = "no sync completed" → never delete).
  ereaderBaseline = "${stateDir}/reconcile/ereader-baseline.json";

  # A python interpreter with the `supernote` LIBRARY importable (the package is a
  # buildPythonApplication, so `toPythonModule` re-exposes its modules to withPackages). The
  # reconciler drives `supernote.client` directly — client HTTP API only, never the server's FS store.
  reconcilePython = pkgs.python313.withPackages (ps: [ (ps.toPythonModule pkgs.supernote) ]);

  # Shared systemd hardening for the supernote units (server + ereader reconcile) — one source so
  # the two can't drift. Both only need outbound TCP + loopback, and both keep their writable state
  # under a systemd-managed dir (StateDirectory / RuntimeDirectory), so ProtectSystem=strict (whole
  # hierarchy read-only, reads intact) and ProtectHome (each unit's HOME is under /var/lib or /run,
  # never /home or /root) are both safe. The reconcile unit additionally opens `library/ereader{,-outbox}/`
  # via ReadWritePaths (it now writes the mirror, not just reads it).
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

    # The `ereader` round-trip (ADR-0031 v2, palimpsest#107) — off by default because it couples
    # to the git-annex `library` tree, which only exists on the media node (rk1b). The base server
    # profile above stays host-agnostic; a host with the library turns this on.
    ereader = {
      enable = lib.mkEnableOption "the ereader round-trip — mirror the store's ereader folder down into library/ereader/ (durable device deletes) and one-shot send library/ereader-outbox/ up, on each device-initiated sync (ADR-0031 v2, palimpsest#107)";

      libraryPath = lib.mkOption {
        type = lib.types.str;
        default = "/var/cache/library";
        description = ''
          Root of the git-annex library tree (hosts/rk1/library.nix). Its `ereader/` subfolder is a
          downward mirror of the device (what the device holds, backed up + Stump-indexed); drop a
          PDF/EPUB into the sibling `ereader-outbox/` to publish it once onto the Supernote.
        '';
      };

      group = lib.mkOption {
        type = lib.types.str;
        default = "library";
        description = ''
          Group owning the library tree (setgid, so drops stay group-readable). The `supernote`
          user joins it to read/write `ereader/` and `ereader-outbox/`, which are created owned by
          this group.
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
          # When the ereader round-trip is on, join the library group so the reconciler (which runs
          # as this user) can read AND write library/ereader{,-outbox}/ (setgid'd to `group`). Empty
          # otherwise — the base server never touches the library tree.
          extraGroups = lib.optional ecfg.enable ecfg.group;
        };
        users.groups.supernote.gid = 982;

        # The one shared credential, split into two scalar sops secrets from the `supernote` sub-map
        # of profiles/library.yaml (sops extracts scalars, not maps; the `a/b` key path descends
        # into the map). Owned by `supernote` so the service user — which runs both this server's
        # bootstrap oneshot and, later, the reconciler (#107) — can read them.
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
            # `supernote cloud login` (bootstrap + reconciler) caches its token under $HOME/.cache;
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

            # A stable JWT signing key so device + reconciler access tokens survive a server
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

      # ── The ereader round-trip (ADR-0031 v2, palimpsest#107) ────────────────────────────────
      (lib.mkIf ecfg.enable {
        # Make library/ereader/ (the mirror) and library/ereader-outbox/ (the one-shot send inbox)
        # exist: group-writable + setgid, owned by the tree owner (git-annex, like the rest of the
        # library) so both the reconciler (supernote user, via the library group) and manual drops
        # stay readable/writable. 2770 not 2775 — the tree is not world-readable. A oneshot rather
        # than a tmpfiles rule so it can wait for the /var/cache NVMe mount — the git-annex module
        # avoids a plain tmpfiles rule here for exactly that mount-race reason. `install -d` is
        # idempotent and applies the same owner/group/mode git-annex would, so ordering against
        # git-annex-init is immaterial (both converge).
        systemd.services.supernote-ereader-dir = {
          description = "Ensure the library ereader/ + ereader-outbox/ folders exist (group-writable, setgid)";
          wantedBy = [ "multi-user.target" ];
          unitConfig.RequiresMountsFor = [ ecfg.libraryPath ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/install -d -o git-annex -g ${ecfg.group} -m 2770 ${ereaderLocalDir} ${ereaderOutboxDir}";
          };
        };

        # The reconcile oneshot — fired by the watcher on each device-initiated sync, never on a
        # timer. Logs in with the shared credential, one-shot-sends the outbox up, then mirrors the
        # store's ereader folder down into library/ereader/ (durable device-side deletes via the
        # baseline). Client HTTP API only; never touches the server's FS store. Trigger-only: no
        # wantedBy, so it runs solely when the watcher `systemctl start`s it.
        systemd.services.supernote-ereader-reconcile = {
          description = "Reconcile the Supernote store with library/ereader/ (mirror down + one-shot send, palimpsest#107)";
          after = [
            "supernote-server.service"
            "supernote-ereader-dir.service"
          ];
          requires = [
            "supernote-server.service"
            "supernote-ereader-dir.service"
          ];
          # Wait for the NVMe library mount too — ReadWritePaths below binds paths under it, which
          # fails the namespace setup if the mount is not yet up.
          unitConfig.RequiresMountsFor = [ ecfg.libraryPath ];
          environment = {
            SUPERNOTE_URL = localUrl;
            EREADER_LOCAL_DIR = ereaderLocalDir;
            EREADER_OUTBOX_DIR = ereaderOutboxDir;
            EREADER_REMOTE_DIR = ereaderRemoteDir;
            EREADER_BASELINE = ereaderBaseline;
            # A writable HOME under the unit's private runtime dir (some libs consult $HOME); the
            # reconciler itself caches nothing else — it logs in fresh each run.
            HOME = "/run/supernote-ereader-reconcile";
          };
          serviceConfig = {
            Type = "oneshot";
            User = "supernote";
            Group = "supernote";
            RuntimeDirectory = "supernote-ereader-reconcile";
            RuntimeDirectoryMode = "0700";
            # The reconciler now WRITES the tree (downloads into ereader/, clears the outbox), so it
            # needs those two paths writable under ProtectSystem=strict; everything else stays RO.
            ReadWritePaths = [
              ereaderLocalDir
              ereaderOutboxDir
            ];
            # The baseline lives inside the server store dir (see the header). StateDirectory=supernote
            # is shared with the server (same static user, same dir) — it makes /var/lib/supernote
            # writable under the sandbox and ensures it exists; 0700 to not loosen the server's mode.
            StateDirectory = "supernote";
            StateDirectoryMode = "0700";
            # New tree files must be group-writable (0664) so git-annex (in the library group) can
            # manage/replicate/drop them — the same reach beets has into the music tree (ADR-0028).
            UMask = "0002";
            # Credentials land in a private tmpfs (CREDENTIALS_DIRECTORY), never argv/environ — same
            # shape as the server bootstrap; the same one account, no second auth surface.
            LoadCredential = [
              "user:${config.sops.secrets."supernote/user".path}"
              "password:${config.sops.secrets."supernote/password".path}"
            ];
            ExecStart = pkgs.writeShellScript "supernote-ereader-reconcile-start" ''
              set -euo pipefail
              export SUPERNOTE_USER_FILE="$CREDENTIALS_DIRECTORY/user"
              export SUPERNOTE_PASSWORD_FILE="$CREDENTIALS_DIRECTORY/password"
              exec ${reconcilePython}/bin/python ${./supernote-ereader-reconcile.py}
            '';
          }
          // hardening;
        };

        # The sync-coupled trigger: NOT a timer and NOT a file-watcher (the owner constraint,
        # carried over from #94). It follows the server's journal and fires the reconcile the
        # moment the device opens a sync — POST /api/file/2/files/synchronous/start, which the
        # server's aiohttp access log records (%r request line). Debounced so a burst of starts
        # coalesces into one reconcile. Runs as root: it reads the server unit's journal and
        # `systemctl start`s the reconcile. On restart it follows from the tail (-n0), so historical
        # sync lines are never replayed.
        systemd.services.supernote-ereader-watch = {
          description = "Fire the ereader reconcile when the Supernote starts a sync (palimpsest#107)";
          wantedBy = [ "multi-user.target" ];
          after = [ "supernote-server.service" ];
          wants = [ "supernote-server.service" ];
          serviceConfig = {
            Restart = "always";
            RestartSec = 5;
            ExecStart = pkgs.writeShellScript "supernote-ereader-watch-start" ''
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
                          echo "ereader watch: device sync detected, firing reconcile"
                          # Keep the follower alive even if the enqueue momentarily fails (set -e
                          # would otherwise tear down the pipeline and bounce the whole watcher).
                          ${pkgs.systemd}/bin/systemctl start --no-block supernote-ereader-reconcile.service || true
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
