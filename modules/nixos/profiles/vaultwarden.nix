# Vaultwarden — the self-hosted vault that holds this operator's credentials
# (users#32, ticket users#39).
#
# A host-agnostic profile, enabled with `custom.profiles.vaultwarden.enable = true` (kelpy,
# the Caddy edge). It is the ONE place the operator's passwords live: Brave fills from it
# through the official Bitwarden extension, mbsync/msmtp read from `rbw`, and Emacs resolves
# forge tokens through an `auth-source` backend over `rbw`. The client half is declared in the
# `users` flake, not here.
#
# Vaultwarden, not official Bitwarden self-host: AGPL, one Rust binary, SQLite, invitations
# built in, and it speaks the API the official clients expect — so the extension and every
# CLI work unchanged (users#35 verified its importer is byte-identical to upstream's). It fits
# beside navidrome.nix rather than dwarfing it. Built from THIS repo's pin: 1.37.3, web vault
# 2026.7.0+0, cached on both arches.
#
# ── What this vault deliberately does NOT do ──────────────────────────────────────────────
#   * NO SMTP. One human, no notifications to deliver — and the bootstrap does not need it:
#     with SIGNUPS_ALLOWED=false and INVITATIONS_ALLOWED=true, `/admin`'s Invite User writes
#     an invitation row (admin.rs `invite_user` takes the no-mail branch) and Vaultwarden
#     checks that row BEFORE the signup gate, so account #1 registers against a closed
#     instance with no mail path (users#34, users#46).
#   * NO signups, ever. The invitation above is the only way an account comes into being.
#   * NO second user. Serving friends and family is out of scope on users#32; it would need
#     public HTTPS, SMTP and restore drills other people depend on.
#   * NO offsite backup wired here, still — but the ARTIFACT a backup would need now EXISTS
#     (users#57). `vaultwarden-db-dump.service` takes Vaultwarden's own `VACUUM INTO` dump
#     every night, and the host's restic job ships THAT while excluding the live db.sqlite3;
#     see hosts/kelpy/configuration.nix for the exclude and the freshness gate. Whether any
#     restic job runs on this host at all is still fleet-wide (palimpsest#150) and still off.
#     ⚠ The old note here said kelpy's job "already declares /persistent". It no longer does:
#     ADR-0036 replaced the bulk root with an enumerated path list, in which
#     /persistent/var/lib/vaultwarden is named explicitly.
#   * NO account provisioning oneshot, unlike forge.nix. There is nothing to call: the
#     binary's only subcommands are `hash` and `backup` (users#32's Notes), so account #1 is
#     invited through `/admin` and its master password is set in the browser, by hand, once.
#
# ── The master password is the whole of the security model ────────────────────────────────
# Established from primary sources on users#37: there is NO password-reset route in `/admin`,
# no key connector (hardcoded false), no PRF/passkey login (a deliberate empty stub), and
# Emergency Access needs a second account this instance will not have. A forgotten master
# password is UNRECOVERABLE. The one warm path is auth requests ("log in with device"), which
# are fully implemented, unconfigurable and on by default — so every already-logged-in
# unlockable client is itself a key custodian, and an unattended unlocked seat is equivalent
# to the vault.
#
# ── Third-party hardware (users#37's second rider) ────────────────────────────────────────
# kelpy is a vpsAdminOS container on vpsFree — hardware this operator does not own. What the
# host can see is therefore part of the design, not an afterthought:
#
#   * The secret fields are client-encrypted. In the `ciphers` table, `name`, `notes`,
#     `fields` and `data` are Bitwarden EncStrings; the server never holds a key that opens
#     them (schema read at migrations/sqlite/2018-*/up.sql).
#   * The metadata is NOT. Cleartext in db.sqlite3: the account email and display name, item
#     and folder COUNTS, types, favourites, every created/updated timestamp, and — now that
#     users#47 has enrolled TOTP — the second factor's own shared secret. NOT in
#     `users.totp_secret`, which this header used to name and which is DEAD CODE: the field is
#     `_totp_secret` on the Db struct, never read, always written None, and the 2018 U2F
#     migration nulled the column. The seed is the raw uppercase base32 string in
#     `twofactor.data`, a plain TEXT column with no hashing or encryption anywhere, so whoever
#     holds this file generates valid codes forever. Accepted rather than overlooked: users#47
#     enrolled the factor against master-password DISCLOSURE, and against the disk-holder
#     modelled here a second factor was never the control. WebAuthn is the only factor that
#     would survive a DB read, and `rbw` cannot complete one.
#   * The recovery code (`users.totp_recover`) is cleartext here too, and so is a personal API
#     key (`users.api_key`) if one ever exists — which additionally BYPASSES 2FA outright
#     (identity.rs: "Note that API key logins bypass 2FA"). users#47 made "never provision
#     one" policy, and nothing here needs to: Vaultwarden issues no captcha, so `rbw login`
#     never falls through to `rbw register`.
#   * NO STANDING OFF-MACHINE EXPORT, and the reasoning is worth keeping because it inverts
#     what users#32's fog said (operator's call, users#57, 2026-10-14). The fog note had the
#     export covering "a forgotten master password" — but users#37 already custodies that, on
#     paper, off-machine. What an export actually insures against is FORMAT and SOFTWARE risk:
#     restic hands back the dump and nothing can open it. That is remote, slow-moving, and —
#     decisively — an export can be taken at any time while the vault still works, so holding
#     one in advance buys almost nothing against a second complete copy of every password, plus
#     custody of that copy's own encryption password. So one is taken only at a NAMED TRIGGER:
#     before a master-password rotation, before a KDF change, or before a migration off
#     Vaultwarden. Not on a cadence, and not "just in case".
#   * So the realistic threat is an offline attack on the vault blob by whoever holds the
#     disk, which is exactly a brute-force against the master-password KDF. That is the
#     reason the master password is long and the KDF left at the client's Argon2id default,
#     and the reason the paper record of it lives off-machine (users#37's break-glass set).
#   * DISABLE_ICON_DOWNLOAD closes the other leak: by default the SERVER fetches a favicon
#     for every URI in the vault, which hands kelpy's network path the operator's site list.
#
# ── Reverse proxy ─────────────────────────────────────────────────────────────────────────
# Caddy fronts this at vault.<domain> behind the `internal_only` tailnet guard, derived from
# the `vault` entry in parts/settings.nix (proxy.nix: the registry attribute name IS the vhost
# subdomain). CO-LOCATED with the edge, so it listens on loopback and needs no firewall rule
# at all. HTTPS is not optional and there is no http shortcut for a first test: the Bitwarden
# extension's own URL validator and WebCrypto both demand it (users#32's Notes). A Tailscale
# cert was considered and rejected — this fleet has never issued one.
{
  config,
  lib,
  pkgs,
  self,
  settings,
  ...
}:
let
  cfg = config.custom.profiles.vaultwarden;

  # Endpoint metadata comes from the `vault` service entry in settings: the port it listens
  # on, and the edge host where Caddy fronts it. The registry attribute name IS the vhost
  # subdomain, so the public URL is derived rather than repeated. `vault` and not
  # `vaultwarden`: the same split navidrome/`music` and stump/`library` already use — the
  # profile is named for the software, the registry key for the URL a human types.
  svcName = "vault";
  svc = settings.services.private.${svcName};

  domain = "${svcName}.${settings.primaryDomain}";
  publicUrl = "https://${domain}";

  # Upstream computes its StateDirectory from `system.stateVersion` and exposes the result
  # nowhere, so the same rule is repeated here — and the assertion below reads the unit back
  # to prove the two still agree, because every path in this file hangs off it.
  stateDirName =
    if lib.versionOlder config.system.stateVersion "24.11" then "bitwarden_rs" else "vaultwarden";
  dataDir = "/var/lib/${stateDirName}";

  # ── WHERE config.json IS SENT TO DIE (users#46) ─────────────────────────────────────────
  # `/admin` exists here, and its Save button is a loaded gun: config.json really does
  # outrank the environment (config.rs `load()`: `env.merge(&usr, …)`, file wins), and ONE
  # Save persists all 88 editable keys — INCLUDING ADMIN_TOKEN — so a single click would
  # silently outrank every future sops rotation, with the startup warning and the Diagnostics
  # row blind to it (both are computed from `env ∩ file`).
  #
  # The fix is not a placeholder, a bind mount or a tmpfiles rule: it is to point CONFIG_FILE
  # at a path whose PARENT DOES NOT EXIST, as a sibling of the state dir under /var/lib —
  # which `ProtectSystem = "strict"` already mounts read-only for this unit. opendal's Fs
  # operator is rooted at that parent, so the write gets EROFS and Save answers a clean 400,
  # while startup is unaffected: `ConfigBuilder::from_file().await.unwrap_or_default()`
  # swallows the read error and the config is env + defaults, always.
  #
  # Deliberately NOT a path inside `dataDir`, which is the one directory this unit CAN write.
  configDir = "/var/lib/${stateDirName}-config";
  configFile = "${configDir}/config.json";

  # Upstream declares no `services.vaultwarden.user` option — it reads the account straight
  # off `users.users.vaultwarden`, so read it from the same place rather than restating the
  # literal in four spots.
  vwUser = config.users.users.vaultwarden.name;
  vwGroup = config.users.groups.vaultwarden.name;

  alertPost = import ../../shared/alert-post.nix { inherit lib pkgs; };
in
{
  options.custom.profiles.vaultwarden = {
    enable = lib.mkEnableOption ''
      Vaultwarden, the self-hosted vault this home reaches from Brave and from Emacs
      (users#32). Tailnet-only, memory-capped, single-account, SQLite. Enable on the Caddy
      edge host (kelpy)
    '';

    secretFile = lib.mkOption {
      type = lib.types.path;
      default = self.lib.getSecretFile "vaultwarden";
      defaultText = lib.literalExpression ''self.lib.getSecretFile "vaultwarden"'';
      description = ''
        sops file holding `vaultwarden/admin_token` — an Argon2id PHC string, as produced by
        `vaultwarden hash` (users#46), NOT the token itself. The plaintext token is never
        stored on the fleet: it belongs in the operator's off-machine break-glass set beside
        the paper record of the master password (users#37).

        ⚠ Its recipients must be `&admin, &kelpy` only. sops grants per FILE, not per key, so
        any reference to it has to stay host-scoped — a fleet-wide declaration would ask a
        host that cannot decrypt it to install it, and `sops-install-secrets` is
        ALL-OR-NOTHING per host, so that host would then install none of its secrets
        (AGENTS.md).
      '';
    };

    memoryMax = lib.mkOption {
      type = lib.types.str;
      default = "512M";
      description = ''
        The blast-radius fence, in `MemoryMax=` form. kelpy is a 4 GB vpsAdminOS container
        WITH NO SWAP where Immich once OOM-looped and took tuwunel and jellyfin with it, so
        this is a fence and not a tuning knob — see forge.nix's `serviceConfig` note for why
        `MemoryHigh` cannot be the mechanism on a swapless host.

        Provisional, like the forge's: sized by what the host can spare (1.1 GB available,
        measured 2026-10-06, of which the forge may take 1 G) rather than by a measured
        Vaultwarden footprint, because there is no measurement yet — the cgroup-memory metric
        lands in the SAME deploy, which is what the tighten step reads.

        One floor it must not go under: verifying the `/admin` token runs Argon2id at the
        `bitwarden` preset — m=64 MiB, t=3, p=4 — so a cap near the idle footprint would turn
        every admin login into an OOM kill.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      default = dataDir;
      defaultText = lib.literalExpression ''"/var/lib/vaultwarden"'';
      description = ''
        Read-only: where the vault's state lives, including the dumps. Exposed so a host's
        backup job can DERIVE its paths, its exclude and its freshness gate from the profile
        instead of restating the literal — the pattern `custom.profiles.immich.mediaLocation`
        already sets for hosts/rk1/backup.nix.

        It is computed from `system.stateVersion` (upstream's rule, restated here because
        upstream exposes the result nowhere) and an assertion reads the unit back to prove the
        two still agree. On an impermanence host the BACKING STORE is `/persistent` + this.
      '';
    };

    dump = {
      onCalendar = lib.mkOption {
        type = lib.types.str;
        default = "02:30";
        description = ''
          When to take the nightly `VACUUM INTO` dump, as a systemd `OnCalendar=`.

          COUPLED to the host's restic schedule and not freely choosable: kelpy's `daily` job
          runs at 03:00/15:00, so 02:30 leaves half an hour of slack and makes the day's first
          snapshot an almost-consistent pair — the same argument backup.nix makes for pairing
          03:00 with Immich's 02:00 dump. The timer deliberately carries NO
          `RandomizedDelaySec`: jitter is harmless for the drift check beside it and a hazard
          here, where 15 minutes of it would let the dump land on top of the restic run.

          Move this and move `maxDumpAgeSeconds` in hosts/kelpy/configuration.nix with it.
        '';
      };

      keep = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3;
        description = ''
          How many dumps to keep. Retention is OURS: upstream's `backup_sqlite()` writes
          `db_<UTC>.sqlite3` and never prunes, so an unattended nightly signal would grow one
          full copy of the vault per day inside the state directory, forever.

          Small on purpose, and the reason is not disk. Every dump is a COMPLETE copy of the
          vault blob — and of the metadata that is cleartext in it, the TOTP seed in
          `twofactor.data` included (see the third-party-hardware note in this file's header).
          Keeping ten would mean ten copies of that on hardware this operator does not own, to
          buy a restore point nobody wants: an older dump is a vault missing whatever was added
          since. Three is "last night, plus two chances to notice something wrong with it".
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # The HTTP listener is loopback-only, so Caddy can only reach it from the same
        # machine. Correct while the vault is co-located with the edge, and silently wrong
        # the moment someone gives the registry entry an `origin` — the vhost would proxy
        # across the tailnet to a port nothing is listening on out there.
        assertion = (svc.origin or svc.edge) == config.networking.hostName;
        message = "custom.profiles.vaultwarden is enabled on ${config.networking.hostName}, but settings.services.private.vault points its listener at ${svc.origin or svc.edge}. This profile binds Rocket to 127.0.0.1 for a Caddy on the SAME host; running it off-edge needs ROCKET_ADDRESS widened and a tailscale0 firewall rule for the HTTP port.";
      }
      {
        # ── THE LISTEN-ADDRESS TRAP (users#34) ─────────────────────────────────────────
        # `services.vaultwarden.config`'s DEFAULT carries ROCKET_ADDRESS = "::1" and
        # ROCKET_PORT = 8222 — and a default applies only when nothing defines the option.
        # The upstream module always defines it (DATABASE_URL/DOMAIN, even mkIf'd away), so
        # on an enabled host that default is already gone and Rocket's own 0.0.0.0:8000
        # applies unless both are set BY HAND. Measured on users#34: the generated env file
        # then carries no ROCKET_* at all. On this public-facing host that would leave the
        # firewall as the only thing between the vault and the internet, so it is asserted
        # rather than merely written below.
        assertion =
          (config.services.vaultwarden.config.ROCKET_ADDRESS or null) == "127.0.0.1"
          && (config.services.vaultwarden.config.ROCKET_PORT or null) == svc.port;
        message = "custom.profiles.vaultwarden: ROCKET_ADDRESS/ROCKET_PORT must be 127.0.0.1:${toString svc.port} (the registry's `vault` port). Something has overridden them — and Rocket's fallback is 0.0.0.0:8000, which on this host faces the internet.";
      }
      {
        # The config.json fix above is ENTIRELY carried by /var/lib being read-only for this
        # unit, which is `ProtectSystem = "strict"`'s doing and upstream's choice, not ours.
        # If that is ever relaxed, the relocation stops being a fence and `/admin`'s Save
        # starts silently outranking sops again — with no error anywhere.
        assertion = config.systemd.services.vaultwarden.serviceConfig.ProtectSystem == "strict";
        message = "custom.profiles.vaultwarden: vaultwarden.service no longer sets ProtectSystem = \"strict\", so /var/lib is writable for it and CONFIG_FILE=${configFile} is no longer unwritable. The /admin Save button can now persist all 88 editable keys (ADMIN_TOKEN included) over sops. Re-establish an unwritable CONFIG_FILE before deploying.";
      }
      {
        # The relocation only works while the path sits OUTSIDE the one writable directory.
        assertion = !(lib.hasPrefix "${dataDir}/" configFile);
        message = "custom.profiles.vaultwarden: CONFIG_FILE (${configFile}) is inside the state directory ${dataDir}, which this unit can write. /admin's Save would succeed and outrank sops.";
      }
      {
        # Every path here is derived from a stateVersion rule copied out of the upstream
        # module. Read the unit back so a change in that rule is a build error rather than a
        # vault that persists its database somewhere nothing backs up.
        assertion = config.systemd.services.vaultwarden.serviceConfig.StateDirectory == stateDirName;
        message = "custom.profiles.vaultwarden: upstream's StateDirectory is ${config.systemd.services.vaultwarden.serviceConfig.StateDirectory}, but this profile computed ${stateDirName} — so the persistence entry, the CONFIG_FILE sibling and the drift guard are all pointing at the wrong directory.";
      }
    ];

    services.vaultwarden = {
      enable = true;
      dbBackend = "sqlite";

      # Package and webVaultPackage are left at this pin's defaults (1.37.3 / 2026.7.0+0),
      # deliberately unlike forge.nix: there is no LTS-vs-current split to opt out of here.
      config = {
        DOMAIN = publicUrl;

        # Loopback, and both halves stated — see the assertion above for why this is not
        # optional and not inherited. Rocket, not nginx: `configureNginx` is upstream's only
        # consumer of the `domain` option, and this fleet fronts everything with Caddy.
        ROCKET_ADDRESS = "127.0.0.1";
        ROCKET_PORT = svc.port;

        # The bootstrap, and the permanent posture: nobody may sign up, the operator is
        # invited once from /admin, and that invitation row is checked before the signup gate
        # so no mail is needed (users#34).
        SIGNUPS_ALLOWED = false;
        INVITATIONS_ALLOWED = true;

        # Nothing here sends mail, so the password-hint feature cannot deliver one — and the
        # hint is stored server-side in the clear. SHOW_PASSWORD_HINT would additionally
        # print it to an UNAUTHENTICATED requester, which is a free hint about the one secret
        # on this map that cannot be rotated out of trouble. Both off.
        PASSWORD_HINTS_ALLOWED = false;
        SHOW_PASSWORD_HINT = false;

        # The server must not fetch favicons. By default it resolves and GETs an icon for
        # every URI in the vault, from THIS host — handing the operator's site list to a
        # network path on third-party hardware (see the posture note at the top).
        DISABLE_ICON_DOWNLOAD = true;

        # Where config.json is sent to die. See `configFile` above; the assertions are what
        # keep this load-bearing rather than decorative.
        CONFIG_FILE = configFile;

        # Pinned, not inherited: this host ships its journal to VictoriaLogs and caps it
        # (profiles/base.nix), so the volume arriving there should not be able to change
        # under a default flip.
        LOG_LEVEL = "info";
      };

      # Secrets arrive as an env file, which upstream appends AFTER its generated one — and
      # systemd lets a later EnvironmentFile override an earlier one, so ADMIN_TOKEN cannot
      # be shadowed by the store-readable half. A missing or unreadable file FAILS THE UNIT
      # (systemd.exec(5)), which is the behaviour wanted: an admin-less vault that looks
      # healthy would be worse.
      environmentFile = [ config.sops.templates.vaultwarden_env.path ];
    };

    # ── THE ADMIN TOKEN ─────────────────────────────────────────────────────────────────
    # An Argon2id PHC string (users#46), so what sits in the env — and in /proc/<pid>/environ
    # — is a verifier rather than the credential. The plaintext token lives only in the
    # operator's off-machine break-glass set.
    #
    # Single-quoted in the template: a PHC string is full of `$`, and while an unquoted
    # EnvironmentFile value is parsed with POSIX-shell-unquoted BACKSLASH rules only (no
    # variable expansion), the single-quoted form preserves every character verbatim and is
    # what vaultwarden's own .env.template shows. A PHC string contains no single quote.
    sops = {
      secrets.vaultwarden_admin_token = {
        sopsFile = cfg.secretFile;
        key = "vaultwarden/admin_token";
      };
      templates.vaultwarden_env = {
        content = "ADMIN_TOKEN='${config.sops.placeholder.vaultwarden_admin_token}'";
        owner = vwUser;
        group = vwGroup;
        mode = "0400";
      };
    };

    systemd.services.vaultwarden = {
      # ── THE STATE MOUNT MUST EXIST FIRST ──────────────────────────────────────────────
      # The same switch-time race forge.nix documents in detail, and here the LOUD failure
      # is not available: systemd creates `StateDirectory` itself, so if the persistence
      # bind mount is not up yet it would create /var/lib/vaultwarden on the TMPFS ROOT,
      # Vaultwarden would build db.sqlite3 there, the mount would shadow it, and the vault
      # would come up looking perfectly healthy with a database that vanishes at the next
      # reboot. For a password store that is the worst failure on the list.
      unitConfig.RequiresMountsFor = [ dataDir ];
      serviceConfig = {
        # The fence. MemoryMax is the mechanism and MemoryHigh is only a page-cache brake —
        # forge.nix's serviceConfig note has the full derivation (no swap means MemoryHigh
        # throttles towards sleep indefinitely while `systemctl is-active` still says
        # `active`, which the unit-state watcher cannot see).
        MemoryMax = cfg.memoryMax;
        MemoryHigh = "384M";
        # A pin, not a change — DefaultOOMPolicy is already `stop` on this host. Stated
        # because the fence's whole purpose is that a cgroup-local kill takes down the vault
        # and nothing else. Upstream sets `Restart = always`, so a one-off kill self-heals
        # and leaves only the cgroup `oom_kill` counter; a genuine runaway crash-loops past
        # the start limit into `failed`, which is what monitoring-unit-state sees.
        OOMPolicy = "stop";
      };
    };

    # ── THE DRIFT GUARD (users#46) ──────────────────────────────────────────────────────
    # The surviving risk is not a click — the click now fails — it is somebody dropping the
    # CONFIG_FILE relocation in a later edit and nothing noticing, because a config.json that
    # outranks sops produces no warning and no Diagnostics row. So watch BOTH candidate
    # paths: the relocated one (if it exists, /var/lib became writable for this unit) and
    # upstream's default inside the state dir (if it exists, the relocation was dropped, or
    # a file survives from before it).
    #
    # NON-BLOCKING by design: a oneshot on a timer, which nothing depends on and which never
    # gates the vault. Refusing to start a password store over a configuration smell would be
    # the wrong trade — the vault being up is what the operator's logins depend on.
    systemd.services.vaultwarden-config-drift = {
      description = "Alert if a vaultwarden config.json has appeared and is outranking sops (users#46)";
      # Run after the vault, not before it: the interesting state is what exists once the
      # service has had its chance to write.
      after = [ "vaultwarden.service" ];
      unitConfig.RequiresMountsFor = [ dataDir ];
      serviceConfig = {
        Type = "oneshot";
        # Root: the state dir is 0700 vaultwarden, and this check must be able to see into it
        # without being granted the vault's own identity.
        User = "root";
      };
      script =
        let
          post = alertPost.mkPost {
            name = "vaultwarden-config-drift";
            # `or null`-guarded the way every other check here reads it: a host without the
            # matrix stack declares no infraAlerts, and mkPost already degrades to a log
            # line when the url is absent.
            webhookUrlFile = config.custom.profiles.matrix.infraAlerts.webhookUrlFile or null;
            # In-band only. This check runs ON kelpy and posts to kelpy's loopback hookshot,
            # so a kelpy outage stops the check itself and there is no message left to
            # rescue — the asymmetry modules/shared/alert-post.nix spells out.
            outOfBand = null;
          };
        in
        ''
          set -euo pipefail
          ${post}

          found=""
          for candidate in ${lib.escapeShellArg configFile} ${lib.escapeShellArg "${dataDir}/config.json"}; do
            if [ -e "$candidate" ]; then
              found="$found $candidate"
            fi
          done

          if [ -n "$found" ]; then
            post "🚨 [${config.networking.hostName}] vaultwarden — a config.json exists ($found). It OUTRANKS every env var from sops, ADMIN_TOKEN included, and neither the startup warning nor /admin's Diagnostics row can see it. Delete it and check that CONFIG_FILE still points at an unwritable path (users#46)."
            echo "vaultwarden-config-drift: found$found" >&2
            exit 0
          fi

          echo "vaultwarden-config-drift: no config.json at ${configFile} or ${dataDir}/config.json — OK."
        '';
    };

    systemd.timers.vaultwarden-config-drift = {
      description = "Daily check that no vaultwarden config.json is outranking sops (users#46)";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "15m";
        Unit = "vaultwarden-config-drift.service";
      };
    };

    # ── THE BACKUP ARTIFACT (users#57) ───────────────────────────────────────────────────
    # A nightly `VACUUM INTO` dump, because the live database cannot be backed up by copying
    # it. `db.sqlite3` is open with WAL, so a file-level copy is a torn page set plus a
    # `-wal`/`-shm` pair no backup tool can capture atomically beside it — the artifact looks
    # like a database and may not open. The host's restic job therefore EXCLUDES the live
    # triple and ships the dumps instead (hosts/kelpy/configuration.nix).
    #
    # Read out of this pin's source (src/db/mod.rs `backup_sqlite`, 1.37.3), because the whole
    # design depends on exactly what it does: it opens a SECOND, READ-ONLY connection to the
    # database and runs `VACUUM INTO 'db_<UTC %Y%m%d_%H%M%S>.sqlite3'` into the PARENT
    # DIRECTORY OF THE DATABASE. Three consequences, none of them negotiable:
    #   * the dump lands inside the state dir — not a choice, and the reason no new path or
    #     persistence entry is needed here;
    #   * one file per invocation, with upstream pruning NOTHING, so retention is ours (`keep`);
    #   * the target must not already exist — `VACUUM INTO` refuses to overwrite — so two
    #     triggers inside the same UTC second produce one dump and one logged error.
    #
    # SIGUSR1 rather than the `vaultwarden backup` subcommand, which exists in this version and
    # would also work. The signal hands the job to the process that already holds the database,
    # on the connection it already has; the subcommand would need this unit to carry
    # DATABASE_URL and the rest of the sops-rendered environment, duplicating the one thing
    # that must not drift. Upstream registers the handler only when the active backend is
    # SQLite (main.rs), which it is.
    #
    # ⚠ THE SIGNAL IS ASYNCHRONOUS, and that is the trap this unit is shaped around.
    # `systemctl kill` returns as soon as the signal is queued; the VACUUM runs in the vault's
    # own task. A unit that signalled and exited would report SUCCESS for having sent a signal
    # — green forever while the backup rots — so this one WAITS for the artifact, verifies it
    # is a readable database, and fails otherwise. That is what makes the exit status mean
    # something, and what lets the freshness gate on the host be a second line rather than the
    # only one.
    systemd.services.vaultwarden-db-dump = {
      description = "Take a consistent VACUUM INTO dump of the vault database (users#57)";
      # After, but NOT Requires/Requisite: a dependency failure here would say "job failed"
      # and nothing else, where the script can say which of the three states it found. It also
      # must not be able to START the vault — a dump is not a reason to bring up a password
      # store that something else deliberately stopped.
      after = [ "vaultwarden.service" ];
      unitConfig.RequiresMountsFor = [ dataDir ];
      path = [
        pkgs.coreutils
        pkgs.findutils
        pkgs.sqlite
        config.systemd.package
      ];
      serviceConfig = {
        Type = "oneshot";
        # Root: the state dir is 0700 vaultwarden and the dumps are 0600 inside it, so this
        # unit cannot read its own output without either root or the vault's identity — and
        # taking the vault's identity would let it write the database it is meant to copy.
        User = "root";
      };
      script =
        let
          post = alertPost.mkPost {
            name = "vaultwarden-db-dump";
            webhookUrlFile = config.custom.profiles.matrix.infraAlerts.webhookUrlFile or null;
            # In-band only, as the drift check beside it: this runs ON kelpy and posts to
            # kelpy's loopback hookshot, so a kelpy outage stops the unit and there is no
            # message left to rescue.
            outOfBand = null;
          };
          dir = lib.escapeShellArg dataDir;
        in
        ''
          set -euo pipefail
          ${post}

          if ! systemctl is-active --quiet vaultwarden.service; then
            post "🚨 [${config.networking.hostName}] vaultwarden — no database dump taken: vaultwarden.service is not active, so there is no process to signal. The live db.sqlite3 is excluded from the backup, so tonight's restic run will refuse rather than ship a vault-less snapshot (users#57)."
            echo "vaultwarden-db-dump: vaultwarden.service is not active — nothing to signal." >&2
            exit 1
          fi

          # -1 second: the dump's mtime is the time of the VACUUM, which is at or after the
          # signal, and filesystem/clock granularity should not be able to hide it by a tick.
          t0=$(( $(date +%s) - 1 ))
          systemctl kill -s USR1 vaultwarden.service

          dump=""
          deadline=$(( t0 + 120 ))
          while :; do
            dump=$(find ${dir} -maxdepth 1 -type f -name 'db_*.sqlite3' -newermt "@$t0" \
              -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)
            [ -n "$dump" ] && break
            if [ "$(date +%s)" -ge "$deadline" ]; then
              post "🚨 [${config.networking.hostName}] vaultwarden — the database dump did not appear within 120s of SIGUSR1. The vault is running but produced no db_*.sqlite3; look for 'Backup failed' in its journal. The live db.sqlite3 is excluded from the backup, so the next restic run will refuse (users#57)."
              echo "vaultwarden-db-dump: no new db_*.sqlite3 in ${dataDir} within 120s of SIGUSR1." >&2
              exit 1
            fi
            sleep 2
          done

          # Mode first, before anything else reads it: restic preserves modes, so a dump left
          # group- or world-readable would be restored that way OUTSIDE the 0700 directory
          # that is currently its only protection. Upstream's UMask is 0077 today and this
          # file does not own that, so set it rather than assert it.
          chmod 0600 "$dump"

          # The one check that distinguishes a dump from a file: a truncated or torn VACUUM
          # output is still a plausible-looking sqlite3 file, and the time to find out is not
          # during a restore.
          if ! check=$(sqlite3 -readonly "$dump" 'PRAGMA integrity_check;' 2>&1) \
            || [ "$check" != "ok" ]; then
            # DELETE the bad dump, deliberately. Leaving it would make it the newest file in
            # the directory, so the host's freshness gate would pass and restic would ship a
            # CORRUPT vault; removing it lets the gate fall back to last night's good dump and
            # start failing on its own once that ages out. A stale vault beats an unopenable
            # one, and this unit has already failed either way.
            rm -f "$dump"
            post "🚨 [${config.networking.hostName}] vaultwarden — the database dump FAILED ITS INTEGRITY CHECK and has been deleted: $check. The backup will fall back to the previous dump until it ages past the freshness limit, then refuse (users#57)."
            echo "vaultwarden-db-dump: integrity_check on $dump said: $check" >&2
            exit 1
          fi

          # Logged every night on purpose: these two numbers are what a restore is verified
          # against (users#57's drill compares them to the live vault), and a vault that
          # silently loses rows is otherwise invisible until someone looks for a password.
          total=$(sqlite3 -readonly "$dump" 'select count(*) from ciphers;')
          live=$(sqlite3 -readonly "$dump" \
            'select count(*) from ciphers where deleted_date is null;')
          echo "vaultwarden-db-dump: $dump — integrity ok, $total ciphers ($live live, $(( total - live )) in trash), $(stat -c %s "$dump") bytes."

          # Retention. Upstream prunes nothing, so without this the state directory grows one
          # full copy of the vault per night, forever.
          find ${dir} -maxdepth 1 -type f -name 'db_*.sqlite3' -printf '%T@ %p\n' \
            | sort -rn \
            | tail -n +${toString (cfg.dump.keep + 1)} \
            | cut -d' ' -f2- \
            | while read -r old; do
                echo "vaultwarden-db-dump: pruning $old (keeping ${toString cfg.dump.keep})"
                rm -f "$old"
              done
        '';
    };

    systemd.timers.vaultwarden-db-dump = {
      description = "Nightly consistent dump of the vault database (users#57)";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.dump.onCalendar;
        # A missed dump is taken at boot rather than skipped — the host's freshness gate is
        # tuned on the assumption that downtime does not cost a dump.
        Persistent = true;
        # NO RandomizedDelaySec, unlike the drift check above: this one has to land before the
        # host's restic run, and jitter is exactly what would let it land during one.
        AccuracySec = "1m";
        Unit = "vaultwarden-db-dump.service";
      };
    };

    # ONE directory: db.sqlite3, the attachments and sends folders, the RSA keypair
    # Vaultwarden generates on first start, and the icon cache all live under it.
    #
    # ⚠ Impermanence wipes the tmpfs root but NEVER prunes /persistent. If this vault is ever
    # retired, its state — the encrypted vault blob included — stays behind here invisibly;
    # removing the profile is not enough.
    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        {
          directory = dataDir;
          user = vwUser;
          group = vwGroup;
          # Upstream's StateDirectoryMode, restated so the persisted copy cannot be laxer
          # than the directory systemd would have made.
          mode = "0700";
        }
      ];
    };

    # No firewall rule, deliberately. Rocket is bound to 127.0.0.1 and reached only by the
    # Caddy on this same host; the vault has no second protocol to open (unlike the forge's
    # git-over-SSH). Opening the registry port on any interface would bypass the
    # `internal_only` guard AND the TLS the clients require.
  };
}
