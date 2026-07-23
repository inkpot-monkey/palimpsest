# The Supernote fork's Private Cloud server (ADR-0031, palimpsest#92) — the device sync
# endpoint the Nomad binds via *Settings → Sync → Private Cloud*. A host-agnostic profile,
# enabled with `custom.profiles.supernote.enable = true` (rk1b, which shares the Nomad's
# home LAN 192.168.1.0/24). Packaged as `pkgs.supernote` (palimpsest#91).
#
# Plain HTTP on the LAN — no TLS, no Caddy edge, no tailnet. The device is a locked-down
# Android tablet that can't run Tailscale, so it reaches rk1b directly on the LAN; that is
# why this service is NOT in `settings.services` (which is the Caddy-fronted, uptime-probed
# registry) and gets no vhost/monitor entry. The reconciler (#94) reaches the store over
# this same HTTP API, never the filesystem, so the store below stays private.
#
# The fork ALSO starts an MCP server (its LLM surface) on a second port — LLM features are
# out of v1, so that port is deliberately left OUT of the firewall allow-list (the fork has
# no flag to disable it; it always binds `config.host`). Firewalling it off is what
# satisfies "do not expose the MCP port".
#
# ── The store (`/var/lib/supernote`) ─────────────────────────────────────────────────────
# One directory: the fork's UUID blob store + SQLite VFS + cache. Owned by the private
# `supernote` user 0700 and — deliberately — NOT in the `library` group: the reconciler
# reaches content over the client HTTP API, never the FS. Persisted WHOLE via impermanence +
# StateDirectory (ADR-0004 pattern). It is a strict, REBUILDABLE subset of the offsite-backed
# `library/` tree (hosts/rk1/library.nix), so — unlike `library/` — it has NO kelpy replica
# and NO offsite backup, and nothing here adds it to a restic path (restic is off fleet-wide
# on rk1b anyway; only the telemetry job is declared). Recovery if the store is lost:
#   • device intact  → re-pair the Nomad to the server and let Private Cloud Sync re-seed it;
#   • device gone     → the importer (#94 outbound pass) re-pushes from `library/`.
# Before a `nix flake update supernote` (which can alembic-migrate the DB), take a local
# `sqlite3 .backup` of /var/lib/supernote/system/supernote.db first (ADR-0031 consequence).
#
# ── The credential (one sops secret, shared with the reconciler) ──────────────────────────
# The Supernote account user (email) + password. The server binary itself reads no
# user/password env var; the credential's server-side consumer is the `supernote-account-bootstrap`
# oneshot below, which registers the single account (the fork bootstraps the first user when
# the DB is empty, then locks registration) and proves login works. The SAME secret is what
# the device authenticates with and what the reconciler's client logs in with — one account,
# no second auth surface. sops files are a separate repo (stash): create the secret, then
# `nix flake update secrets` here BEFORE deploy or activation fails (AGENTS.md gotcha).
#
# Lives in the shared `profiles/library.yaml` (this stack's secret bundle, shared with the
# reconciler/#94) under a `supernote` sub-map:
#   supernote:
#     user: you@example.com        # the Supernote account — MUST be a valid email (the fork
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

  # The device binds the sync endpoint here; the MCP port is the fork's always-on LLM
  # surface, kept off the firewall (v1-out). Plain integers, not a settings.services entry
  # (this service is LAN-direct, not Caddy-fronted — see the header).
  port = 8080;
  mcpPort = 8081;

  stateDir = "/var/lib/supernote";
  localUrl = "http://127.0.0.1:${toString port}";
  # The credential lives in the shared library-stack bundle (profiles/library.yaml), under a
  # `supernote` sub-map — see the header. Shared with the reconciler (#94).
  secretsFile = self.lib.getSecretFile "library";
in
{
  options.custom.profiles.supernote = {
    enable = lib.mkEnableOption "the Supernote fork Private Cloud server (device sync endpoint, ADR-0031)";
  };

  config = lib.mkIf cfg.enable {
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
    };
    users.groups.supernote.gid = 982;

    # The one shared credential, split into two scalar sops secrets from the `supernote` sub-map
    # of profiles/library.yaml (sops extracts scalars, not maps; the `a/b` key path descends
    # into the map). Owned by `supernote` so the service user — which runs both this server's
    # bootstrap oneshot and, later, the reconciler (#94) — can read them.
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
      description = "Supernote fork Private Cloud server (device sync endpoint)";
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
        # Self-service registration stays disabled; the fork still allows the FIRST user on an
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
        # restart (the fork otherwise generates a throwaway in-memory key each start, which
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

        # Hardening. StateDirectory stays writable under ProtectSystem=strict; ProtectHome is
        # safe because HOME is /var/lib/supernote (a StateDirectory), not under /home or /root.
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
    };

    # Open ONLY the sync port. It goes on all interfaces (not scoped to `tailscale0` like the
    # tailnet services — the Nomad is LAN-only and can't run Tailscale, and rk1's physical NIC
    # isn't statically named here to scope to); the tailnet is trusted and every request is
    # login-gated, so the extra reach is harmless. The MCP port (${toString mcpPort}) is
    # deliberately absent — the fork always binds it to the same host, so leaving it out of the
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
          message = "custom.profiles.supernote: a restic backup now covers the fork store (${stateDir}), but ADR-0031 keeps it OUT of any offsite backup (it is a rebuildable subset of the offsite-backed library/). Remove that path or narrow the backup.";
        }
      ];
  };
}
