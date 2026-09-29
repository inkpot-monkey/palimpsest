# Forgejo — the private forge for NEW private projects (palimpsest#204, ticket #212).
#
# A host-agnostic profile, enabled with `custom.profiles.forge.enable = true` (kelpy, the
# Caddy edge). It hosts the CODE and the ISSUES of projects that are not on GitHub, and it
# exists so an agent can run the wayfinding skills against a tracker that is not public:
# `tea` is the agent's surface (palimpsest#206), wired separately by #213.
#
# Everything below is the delta between the upstream `services.forgejo` module and what this
# fleet needs. Each one is load-bearing; the reason is written next to it because several of
# them fail SILENTLY if dropped.
#
# ── Why Forgejo, and why 16 ───────────────────────────────────────────────────────────────
# Forgejo over Gitea on governance (#204). The upstream module's `package` defaults to
# `forgejo-lts` (15.x), NOT `pkgs.forgejo` (16.x) — so the newer line has to be asked for by
# name. It is asked for because the whole tracker story rests on ISSUE DEPENDENCIES, which
# 16 backs with real endpoints and a server-side guard (#205).
#
# ── What this forge deliberately does NOT do ──────────────────────────────────────────────
# Both a memory decision and a scope decision, settled together in #211:
#
#   * NO package/container registry, NO LFS, NO mirrors, NO releases, NO wiki, NO Actions.
#     Actions in particular is out of scope for the whole map — it needs a runner host, and a
#     swapless kelpy is a non-starter for one.
#   * NO SMTP. Nothing here sends mail; there is one human and no notifications to deliver.
#   * NO registration. The admin below is the only account, created by the oneshot at the
#     bottom because upstream has no `adminUser` option and `useWizard = false` already sets
#     `INSTALL_LOCK`, so there is no wizard left to click through.
#   * NO offsite backup. Ruled out of the map (#208): kelpy's restic is disabled, and turning
#     it on is a fleet-wide question (palimpsest#150), not a forge one. The forge's state is
#     persisted (below) and replicated nowhere.
#
# ── The memory fence ──────────────────────────────────────────────────────────────────────
# kelpy is a 4 GB vpsAdminOS container WITH NO SWAP, and this host's own configuration.nix
# records Immich being OOM-killed here and taking tuwunel and jellyfin down with it. The cap
# below is the fleet's first, and it is a BLAST-RADIUS FENCE, not a tuning knob: its job is to
# make a runaway forge kill only the forge. See the comment at `serviceConfig` for why
# `MemoryHigh` cannot be the mechanism on a swapless host.
#
# ── Reverse proxy ─────────────────────────────────────────────────────────────────────────
# Caddy fronts this at forge.<domain> behind the `internal_only` tailnet guard, derived from
# the `forge` entry in parts/settings.nix (proxy.nix: the registry attribute name IS the vhost
# subdomain). The service is CO-LOCATED with the edge, so it listens on loopback and needs no
# firewall rule for HTTP at all — only the git-over-SSH port is opened, on `tailscale0`.
{
  config,
  lib,
  pkgs,
  self,
  settings,
  ...
}:
let
  cfg = config.custom.profiles.forge;

  # Endpoint metadata comes from the `forge` service entry in settings: the port it listens
  # on, and the edge host where Caddy fronts it. The registry attribute name IS the vhost
  # subdomain, so it is named once here and the public URL is derived rather than repeated.
  svcName = "forge";
  svc = settings.services.private.${svcName};

  publicUrl = "https://${svcName}.${settings.primaryDomain}";

  # ALL durable state lives under this one root (#207), which is what makes the single
  # impermanence entry below sufficient. The assertion further down holds that invariant:
  # upstream lets `repositoryRoot`, `customDir`, `lfs.contentDir`, the sqlite path and the
  # dump dir each be moved OUT of it independently, and moving any one of them would leave
  # the persistence line silently covering less than it claims to.
  stateDir = config.services.forgejo.stateDir;

  fj = lib.getExe config.services.forgejo.package;
in
{
  options.custom.profiles.forge = {
    enable = lib.mkEnableOption ''
      Forgejo, the private forge for new private projects (palimpsest#204). Tailnet-only,
      memory-capped, git + issues only. Enable on the Caddy edge host (kelpy)
    '';

    adminUser = lib.mkOption {
      type = lib.types.str;
      default = "inkpotmonkey";
      description = ''
        The forge's single account, created by the provisioning oneshot from
        `forgejo/admin_password` in the secret file. Registration is disabled, so this is the
        only way an account comes into being — and it is a real daily-use login, not a
        bootstrap-only identity like Stump's server owner: there is one human here, and the
        agent tokens (#213) are minted against this account.
      '';
    };

    adminEmail = lib.mkOption {
      type = lib.types.str;
      default = settings.admin.email;
      defaultText = lib.literalExpression "settings.admin.email";
      description = ''
        Email on the admin account. Cosmetic: Forgejo requires one, and with no SMTP wired
        nothing is ever sent to it.
      '';
    };

    sshPort = lib.mkOption {
      type = lib.types.port;
      default = 2222;
      description = ''
        Port for Forgejo's BUILT-IN SSH server, and the port that appears in every clone URL
        the web UI renders.

        Deliberately not 22, and deliberately not host sshd. Forgejo's sshd integration works
        by writing into a real user's `authorized_keys`, and kelpy's admin SSH key IS the sops
        `&admin` key (AGENTS.md) on a host marked `contract.exposed` — so the built-in server,
        which speaks its own protocol in-process and touches no host account, is the only
        arrangement that does not put forge keys anywhere near that. The upstream module
        reinforces the separation: it only ever writes `services.openssh` when the built-in
        server is OFF (its `AcceptEnv = GIT_PROTOCOL` line), so with it on, host sshd is
        untouched.
      '';
    };

    secretFile = lib.mkOption {
      type = lib.types.path;
      default = self.lib.getSecretFile "forgejo";
      defaultText = lib.literalExpression ''self.lib.getSecretFile "forgejo"'';
      description = ''
        sops file holding `forgejo/admin_password` (and, once the forge is up, the per-host
        agent tokens #213 consumes).

        ⚠ Its recipients are `&admin, &kelpy, &sawtoothShark` only — three of the fleet's
        seven. sops grants per FILE, not per key, so ANY reference to it must be host-scoped:
        a fleet-wide declaration would ask a host that cannot decrypt it to install it, and
        `sops-install-secrets` is ALL-OR-NOTHING per host — that host would then install none
        of its secrets (AGENTS.md).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # The whole persistence story is "one directory". Upstream lets each of these be
        # relocated independently, and a relocation would not fail anything — it would just
        # quietly put repositories, or the database, on the tmpfs root, where they vanish at
        # the next reboot. #207 flagged exactly this; the assertion makes it a build error.
        assertion = lib.all (p: lib.hasPrefix "${stateDir}/" p || p == stateDir) [
          config.services.forgejo.repositoryRoot
          config.services.forgejo.customDir
          config.services.forgejo.lfs.contentDir
          config.services.forgejo.database.path
          config.services.forgejo.dump.backupDir
        ];
        message = "custom.profiles.forge: a Forgejo path was moved outside ${stateDir}, which is the ONLY directory this profile persists. Either keep it under the state dir or add the new location to environment.persistence.";
      }
      {
        # The HTTP listener is loopback-only, so Caddy can only reach it from the same
        # machine. That is correct while the forge is co-located with the edge and silently
        # wrong the moment someone gives the registry entry an `origin` — the vhost would
        # proxy across the tailnet to a port nothing is listening on out there.
        assertion = (svc.origin or svc.edge) == config.networking.hostName;
        message = "custom.profiles.forge is enabled on ${config.networking.hostName}, but settings.services.private.forge points its listener at ${svc.origin or svc.edge}. This profile binds HTTP to 127.0.0.1 for a Caddy on the SAME host; running it off-edge needs HTTP_ADDR widened and a tailscale0 firewall rule for the HTTP port.";
      }
    ];

    services.forgejo = {
      enable = true;
      # NOT the module default. `mkPackageOption pkgs "forgejo-lts"` gives the 15.x LTS line;
      # the tracker design rests on 16's issue dependencies (#205), so the current line is
      # named explicitly.
      package = pkgs.forgejo;
      database.type = "sqlite3";

      # Off, and stated rather than inherited: LFS is a second content store that would sit
      # outside the database, and this forge holds source and issues.
      lfs.enable = false;

      settings = {
        server = {
          # Behind Caddy, all four of these have to be set BY HAND. The module's computed
          # default for ROOT_URL is `http://<DOMAIN>:<HTTP_PORT>/`, which is the wrong scheme
          # AND the wrong port here — and ROOT_URL is what Forgejo renders into clone URLs,
          # OAuth redirects and every absolute link in the UI, so getting it wrong produces a
          # forge that looks fine until something follows a link it generated (#207).
          PROTOCOL = "http";
          HTTP_ADDR = "127.0.0.1";
          HTTP_PORT = svc.port;
          DOMAIN = "${svcName}.${settings.primaryDomain}";
          ROOT_URL = "${publicUrl}/";

          # Forgejo's own SSH server, in-process. See the `sshPort` option for why this
          # rather than host sshd. SSH_LISTEN_PORT is what it binds; SSH_PORT is what it
          # PRINTS in clone URLs — they are separate settings and both must be set, or the
          # UI hands out a clone URL pointing at port 22 (i.e. at host sshd).
          START_SSH_SERVER = true;
          SSH_LISTEN_PORT = cfg.sshPort;
          SSH_PORT = cfg.sshPort;
          # Bind on all interfaces and let the firewall scope it to `tailscale0` (below).
          # This is the fleet pattern and it is deliberate: an eval-time tailscale IP literal
          # rots the moment the host re-keys, which is the failure that already killed a
          # scrape target here (see settings.nix's note on `hostKeys`).
          SSH_LISTEN_HOST = "0.0.0.0";
        };

        # Served over HTTPS by Caddy, so the session cookie should say so.
        session.COOKIE_SECURE = true;

        service = {
          DISABLE_REGISTRATION = true;
          # LOAD-BEARING, and the reason it is pinned rather than left at its default: BOTH
          # halves of the wayfinding tracker recipe rest on issue dependencies (#210) — the
          # frontier query reads `blocked_by`, and the 412-on-closing-a-blocked-issue guard
          # is what makes a map's ordering enforceable rather than advisory. It IS on by
          # default in Forgejo 16 (#205); pinned so a future default flip is a config change
          # here rather than a tracker that silently stops gating.
          DEFAULT_ENABLE_DEPENDENCIES = true;
        };

        # The issue indexer, `db` not the default `bleve`. bleve is a SECOND, in-process,
        # memory-resident index over the same issues the database already holds — the single
        # biggest thing that can be switched off inside Forgejo's floor (#211). The cost is
        # worse issue SEARCH (substring matching instead of a real index), which is free on a
        # forge with one user. The repo/code indexer is already off by default; don't set it
        # again here.
        indexer.ISSUE_INDEXER_TYPE = "db";

        repository = {
          # Globally off. These are unavailable on every repo and cannot be turned back on
          # per-repo — which is the point: each one is a subsystem with its own storage or
          # its own scheduler, and this forge is git + issues.
          #
          # ⚠ A MISSPELT UNIT NAME IS A STARTUP WARNING, NOT AN ERROR. Measured against a
          # real forgejo 16.0.5: `repo.bogusunit` produced
          #   models/unit/unit.go:LoadUnitConfig() [W] Invalid keys in disabled repo units
          # and the server started anyway with that unit still enabled. So if one of these is
          # ever edited, check the journal — nothing else will tell you. (Also measured:
          # `repo.releases` IS accepted here, despite the published cheat sheet omitting it
          # from the allowed list.)
          DISABLED_REPO_UNITS = lib.concatStringsSep "," [
            "repo.wiki"
            "repo.releases"
            "repo.projects"
            "repo.packages"
            "repo.actions"
          ];
          # What a NEW repo gets: code, issues, pull requests. Nothing else.
          DEFAULT_REPO_UNITS = lib.concatStringsSep "," [
            "repo.code"
            "repo.issues"
            "repo.pulls"
          ];
        };

        # No package/container registry: a second content store, and nothing here publishes
        # artifacts.
        packages.ENABLED = false;

        # No CI. Out of scope for the whole map (#204's Out of scope): Actions needs a runner
        # host, and this one has no swap.
        actions.ENABLED = false;

        # No pull mirrors — a scheduler plus network fetches for repos this forge does not
        # own. `[mirror] ENABLED` and NOT `[repository] DISABLE_MIRRORS`: the latter is the
        # obvious-looking key and forgejo 16 still accepts it, but deprecated, and says so:
        #   config_provider.go:deprecatedSetting() [E] Deprecated config option
        #   `[repository]` `DISABLE_MIRRORS` present. Use `[mirror]` `ENABLED` instead.
        mirror.ENABLED = false;

        # Housekeeping stays ON. `git gc` is the one background job that makes the repository
        # store SMALLER, which is the direction this host cares about (#211).
        "cron.git_gc_repos".ENABLED = true;

        # This host ships its journal to VictoriaLogs, so pin the level rather than inherit a
        # default that could change the volume arriving there.
        log.LEVEL = "Info";
      };
    };

    # ── THE STATE MOUNT MUST EXIST FIRST, AND BE POPULATED AFTER IT APPEARS ───────────────
    # Both halves of this were missing on the first deploy, and the journal caught them 30ms
    # apart (2026-09-29):
    #
    #   14:39:11.011  systemd-tmpfiles-resetup finished — it had just created
    #                 /var/lib/forgejo/{conf,custom,data,log,repositories} on the TMPFS ROOT,
    #                 because the persistence bind mount did not exist yet
    #   14:39:12.019  var-lib-forgejo.mount: "Directory /var/lib/forgejo to mount over is not
    #                 empty, mounting anyway"  ← everything above is now shadowed
    #   14:39:12.082  forgejo-secrets.service starts — 29ms BEFORE the mount finishes
    #   14:39:12.191  Failed to set up mount namespacing: /var/lib/forgejo/custom: No such
    #                 file or directory  (its ReadWritePaths= names a directory that is gone)
    #
    # This is a switch-time race, not a boot-time one: at boot the bind mounts are in place
    # before tmpfiles runs at all. But it is worth fixing rather than declaring first-deploy-
    # only, because the LOUD failure here is the lucky case. Had `forgejo.service` won the
    # same race it would have run `migrate` and built its sqlite database on the tmpfs root,
    # the mount would have shadowed it, and the forge would have come up looking perfectly
    # healthy with an empty database that vanished at the next reboot.
    #
    # So: everything that touches the state dir waits for the mount (`RequiresMountsFor`, the
    # guard stump.nix uses for the same class of bug), and one oneshot re-applies the tmpfiles
    # rules INSIDE the mount once it is there.
    systemd.services.forgejo-state-dirs = {
      description = "Create Forgejo's state directories inside the persisted mount (palimpsest#212)";
      wantedBy = [ "multi-user.target" ];
      unitConfig.RequiresMountsFor = [ stateDir ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # `--prefix` re-runs UPSTREAM'S OWN rules rather than a copy of them. Reimplementing
        # the directory list here would drift the moment the module gains a path — and it
        # would miss the `L+ conf/locale` symlink into the package's locale dir, which is not
        # a directory and is easy to forget.
        ExecStart = "${config.systemd.package}/bin/systemd-tmpfiles --create --prefix=${stateDir}";
      };
    };

    systemd.services.forgejo-secrets = {
      after = [ "forgejo-state-dirs.service" ];
      requires = [ "forgejo-state-dirs.service" ];
      unitConfig.RequiresMountsFor = [ stateDir ];
    };

    systemd.services.forgejo = {
      after = [ "forgejo-state-dirs.service" ];
      requires = [ "forgejo-state-dirs.service" ];
      unitConfig.RequiresMountsFor = [ stateDir ];
      serviceConfig = {
        # ── THE MEMORY FENCE (#211) ───────────────────────────────────────────────────────
        # The fleet's first memory cap. Provisional and deliberately generous: NO trustworthy
        # footprint figure for Forgejo exists (#207), so this is a fence sized by what kelpy
        # can spare (2.2 GB available, measured), not by what Forgejo needs. #215 carries the
        # measure-and-tighten step, and the cgroup-memory metric that lands in the SAME
        # deploy is what it will read.
        #
        # MemoryMax is the mechanism. MemoryHigh is NOT — and the intuitive reading of it
        # ("the gentler limit, so prefer it") is exactly backwards on this host. kelpy has NO
        # SWAP, so the kernel cannot reclaim anonymous memory, which is what a Go heap is.
        # Past MemoryHigh it therefore throttles the process towards sleep and keeps it
        # there, INDEFINITELY, without ever killing it: a forge that hangs forever while
        # `systemctl is-active` still reports `active` — invisible to the unit-state watcher,
        # which only looks for non-active. So MemoryHigh survives here only as a brake on
        # page cache (which IS reclaimable), and MemoryMax must never be dropped in its
        # favour.
        MemoryMax = "1G";
        MemoryHigh = "768M";
        # A pin, not a change: systemd's DefaultOOMPolicy on this host is already `stop`
        # (measured). Stated because the fence's whole purpose is that a cgroup-local kill
        # takes down the forge and nothing else — that behaviour should be visible here
        # rather than inherited silently.
        #
        # Note what it does and does not buy, since upstream sets `Restart = always`: a
        # ONE-OFF OOM kill stops the unit and systemd restarts it, so the forge self-heals
        # and the only trace is the `oom_kill` counter the cgroup-memory metric exports. A
        # genuine runaway crash-loops past the start limit into `failed`, and THAT is what
        # monitoring-unit-state sees.
        OOMPolicy = "stop";
      };
    };

    # Git over SSH, tailnet-only. NOT `networking.firewall.allowedTCPPorts` (every interface,
    # including the public one this VPS faces): the built-in server is opened on `tailscale0`
    # alone, so only tailnet peers can reach it. The HTTP port is deliberately absent — it is
    # bound to 127.0.0.1 and reached only by the Caddy on this same host.
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ cfg.sshPort ];

    # ONE directory. Repositories, the sqlite database, the generated app.ini, and the
    # SECRET_KEY / INTERNAL_TOKEN / JWT secret the module generates on first start all live
    # under it (#207) — and the assertion above is what keeps that true.
    #
    # ⚠ Impermanence wipes the tmpfs root but NEVER prunes /persistent. If this forge is ever
    # retired, its state stays behind here invisibly; removing the profile is not enough.
    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        {
          directory = stateDir;
          user = config.services.forgejo.user;
          group = config.services.forgejo.group;
          mode = "0750";
        }
      ];
    };

    # The admin account's password. A HOST secret, not a user-home one: #209 established
    # there is no home-sops anywhere on this fleet any more, so a "user-scoped" secret here
    # simply IS a host sops secret. Host-scoped by construction — this whole block sits
    # inside `mkIf cfg.enable`, and the profile is enabled on one host.
    sops.secrets.forgejo_admin_password = {
      sopsFile = cfg.secretFile;
      key = "forgejo/admin_password";
      owner = config.services.forgejo.user;
      group = config.services.forgejo.group;
      mode = "0400";
    };

    # ── PROVISIONING ONESHOT ────────────────────────────────────────────────────────────────
    # Upstream has NO `adminUser` option, and `useWizard = false` sets `INSTALL_LOCK` — so
    # there is no wizard to click and no declarative account either. Without this, a freshly
    # deployed forge has a working login page and nothing that can log into it.
    #
    # CREATE-ONLY, like the Navidrome and Stump provisioners: if the account exists it is left
    # completely alone. Rotating the password is therefore a deliberate manual act
    # (`forgejo admin user change-password`), not something a redeploy does behind your back —
    # which matters because this same account owns the agent tokens (#213), and Forgejo
    # revokes nothing when a password changes but a surprise rotation still locks out the
    # human mid-session.
    systemd.services.forgejo-admin-provision = {
      description = "Create the forge's single admin account (palimpsest#212)";
      after = [ "forgejo.service" ];
      requires = [ "forgejo.service" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.RequiresMountsFor = [ stateDir ];
      environment = {
        # The CLI reads the SAME app.ini and database the server does; without these it would
        # look beside its own store path and quietly build a second, empty forge.
        FORGEJO_WORK_DIR = stateDir;
        FORGEJO_CUSTOM = config.services.forgejo.customDir;
        HOME = stateDir;
      };
      path = [
        config.services.forgejo.package
        pkgs.git
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = config.services.forgejo.user;
        Group = config.services.forgejo.group;
        WorkingDirectory = stateDir;
      };
      script = ''
        set -euo pipefail

        # `admin user list` prints a header row plus one row per user, username in column 2.
        #
        # Collected into a variable first, and matched from a here-string, RATHER than piped
        # straight into `grep -q`. Under `pipefail` that pipeline is a trap: `grep -q` exits
        # the instant it matches, `awk` then takes SIGPIPE, and the pipeline's status is 141 —
        # so the HIT would be read as a miss and the oneshot would try to create an account
        # that already exists, failing the unit on every boot after the first.
        existing="$(${fj} admin user list | ${pkgs.gawk}/bin/awk 'NR > 1 { print $2 }')"

        if ${pkgs.gnugrep}/bin/grep -qxF ${lib.escapeShellArg cfg.adminUser} <<< "$existing"; then
          echo "forge: admin account '${cfg.adminUser}' already exists — leaving it untouched."
          exit 0
        fi

        ${fj} admin user create \
          --username ${lib.escapeShellArg cfg.adminUser} \
          --email ${lib.escapeShellArg cfg.adminEmail} \
          --password "$(cat ${config.sops.secrets.forgejo_admin_password.path})" \
          --admin \
          --must-change-password=false
        echo "forge: created admin account '${cfg.adminUser}'."
      '';
    };
  };
}
