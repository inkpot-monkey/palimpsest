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
#   * NO offsite backup wired here. kelpy's restic job already declares /persistent and is
#     merely switched OFF; turning it on is a fleet-wide question (palimpsest#150), and
#     PROVING a restore is still open on users#32. Note Vaultwarden ships its own
#     SQLite-consistent dump (`vaultwarden backup`, or SIGUSR1) — a file-level copy of a live
#     db.sqlite3 is not the same artifact, and whichever job eventually runs should use it.
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
#     and folder COUNTS, types, favourites, every created/updated timestamp, and — if the
#     account ever enables TOTP — `users.totp_secret`, which is the account's own second
#     factor in the clear (users#47's business).
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
