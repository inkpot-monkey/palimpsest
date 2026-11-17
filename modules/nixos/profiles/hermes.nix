{
  config,
  lib,
  inputs,
  pkgs,
  settings,
  self,
  ...
}:

# Hermes Agent (Nous Research) — the fleet's agent runtime, replacing the retired
# `openclaw` profile.
#
# WHY THE SWAP. Both are operator harnesses (cron + durable sessions + channels) rather
# than interactive coding CLIs, and both are top-tier by activity. What decided it is the
# SHAPE OF THE SCHEDULED HALF, which is most of what this host will actually run:
# Hermes gives every cron job a fresh isolated session by construction, writes each run to
# its own file, disables cron-management tools inside cron sessions (a compromised run
# cannot spawn more jobs), and can run a deterministic pre-run script before any tokens are
# spent — collect the fleet logs in Python, then make one model call. OpenClaw can be
# configured to the same place, but there it is a choice rather than a constraint.
#
# What was GIVEN UP: OpenClaw's persistent named sessions, which accumulate context across
# runs. If the exploratory long-running agent turns out to need that, this is the thing to
# re-examine — Hermes cannot do it, and that is a design stance, not a gap.
#
# Hermes ships its own NixOS module (nix/nixosModules.nix in the input), so only host glue
# lives here per the AGENTS.md convention for components in their own repos.
let
  cfg = config.custom.profiles.hermes;

  litellm = settings.services.private.litellm;

  # This profile's own registry entry — the vhost kelpy serves at agent.<domain> and the
  # port the backend binds. Read from the registry rather than restated, so the two cannot
  # drift: Caddy proxies to `${svc.origin}.${tailnet}:${svc.port}`, and that is exactly the
  # address the dashboard must be listening on.
  svc = settings.services.private.agent;

  hermesStateDir = "/var/lib/hermes";

  # ── THE MATRIX END OF THE AGENT ───────────────────────────────────────────────────
  # The homeserver's `server_name` is the Matrix DOMAIN (the half after the colon in an
  # MXID) and it is NOT `settings.primaryDomain` — kelpy's matrix profile names the
  # homeserver `matrix.<primaryDomain>`, so every MXID on this fleet reads
  # `@someone:matrix.palebluebytes.space`. Getting that wrong produces a login that
  # fails with M_FORBIDDEN and looks like a bad password.
  matrixServerName = "matrix.${settings.primaryDomain}";
  # The public Caddy vhost, which is the only address rk1b can reach: tuwunel binds
  # 127.0.0.1 on kelpy and its registry entry is `proxy = false`.
  matrixHomeserver = "https://${matrixServerName}";
  # Kept in step with `custom.profiles.matrix.hermesRooms.botLocalpart` on kelpy; that
  # option lives on the other host, so this is the one fact the two ends restate.
  matrixUserId = "@hermes:${matrixServerName}";
  # Who may talk to the bot. Matches `custom.profiles.matrix.adminLocalpart`, also on
  # kelpy. Without an allowlist the gateway answers nobody, and `MATRIX_ALLOW_ALL_USERS`
  # is a development knob on a tailnet that is not single-person (ADR-0027).
  matrixAdminLocalpart = "inkpotmonkey";

  # The conversational half of the shared catalogue (parts/settings.nix).
  chatModels = lib.filterAttrs (_: m: m.chat) settings.models;
  # `settings.primaryDomain` and NOT `config.networking.domain`, which proxy.nix uses to
  # build the same name: that option is set on the EDGE and is null everywhere else, so
  # reading it here fails the build on the very host this profile runs on ("cannot coerce
  # null to a string", arriving via restartTriggers → toJSON settings).
  publicUrl = "https://agent.${settings.primaryDomain}";

  # Where this host reaches the model gateway. DERIVED from the registry rather than
  # hardcoded to loopback: the two are co-located today (both rk1b), but if either moves
  # this follows instead of silently pointing at a port nothing answers.
  litellmOrigin = litellm.origin or litellm.edge;
  litellmHost =
    if litellmOrigin == config.networking.hostName then
      "127.0.0.1"
    else
      "${litellmOrigin}.${settings.tailnet}";
in
{
  options.custom.profiles.hermes = {
    enable = lib.mkEnableOption "Hermes Agent gateway";
  };

  imports = [ inputs.hermes-agent.nixosModules.default ];

  config = lib.mkIf cfg.enable {
    sops.secrets.litellm_key = {
      sopsFile = self.lib.getSecretPath "profiles/ai.yaml";
      key = "litellm-key";
    };

    # The dashboard's own login. Same file as the LiteLLM key — this host is already a
    # recipient of profiles/ai.yaml, so the credential needs no re-key (see the derived
    # recipient set in `just sops-recipients`).
    sops.secrets.hermes_dashboard_password = {
      sopsFile = self.lib.getSecretPath "profiles/ai.yaml";
      key = "hermes-dashboard-password";
    };
    # Signs the stateless session cookies. WITHOUT IT the provider mints a random key per
    # PROCESS and logs that at INFO only — so every restart, including a deploy that
    # touches the unit, silently logs the operator out mid-session.
    sops.secrets.hermes_dashboard_session_secret = {
      sopsFile = self.lib.getSecretPath "profiles/ai.yaml";
      key = "hermes-dashboard-session-secret";
    };

    # NO NEW SECRET. Hermes reads `CUSTOM_API_KEY` for its `custom` (OpenAI-compatible)
    # provider, and the agent authenticates to our OWN LiteLLM with the same master key
    # every other consumer uses — LiteLLM is what holds the upstream vendor keys. So this
    # host never sees an OpenRouter or Anthropic credential.
    #
    # THE DASHBOARD LOGIN rides the same file. Hermes's bundled `basic` dashboard-auth
    # plugin ships enabled but DORMANT: it raises SkipRegistration until a username and a
    # password reach it, which is why the gate below is configured HERE and not in
    # `settings`. The plugin reads either, and env wins — but `settings` is rendered into
    # config.yaml FROM THE NIX STORE, so a password there would be world-readable on every
    # host that builds this. The env file is sops-rendered at runtime, 0640 hermes:hermes.
    #
    # The password is hashed with scrypt in memory at each start (the plugin's
    # `hash_password`), so what sits at rest is sops's copy and nothing else.
    #
    # ⚠ ROTATING IT NEEDS A MANUAL RESTART. restartTriggers below hash `settings` only, and
    # deliberately — a trigger on the rendered env would put the LiteLLM key in a
    # world-readable unit file. Same trap the config.yaml note documents, one file over.
    # ── THE MATRIX PLATFORM, WHICH IS WHAT GIVES A JOB A CHANNEL ──────────────────────
    # Same account kelpy's `matrix.hermesRooms` registers, same key in the same sops
    # file — rk1b is already a recipient of profiles/matrix.yaml, so nothing is re-keyed
    # and no access token has to travel between the hosts. ⚠ kelpy FIRST: the account has
    # to exist before the gateway logs in.
    #
    # ENV IS THE ONLY PATH. There is no `hermes platforms` CLI and no module option; the
    # plugin reads its configuration from the environment (gateway_env.py), and only ten
    # non-credential knobs can alternatively come from config.yaml. Homeserver, user id,
    # password and device id are NOT among them, so they must be here.
    sops.secrets.hermes_bot_password = {
      sopsFile = self.lib.getSecretFile "matrix";
    };

    sops.templates."hermes-env".content = ''
      CUSTOM_API_KEY=${config.sops.placeholder.litellm_key}
      HERMES_DASHBOARD_BASIC_AUTH_USERNAME=inkpotmonkey
      HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=${config.sops.placeholder.hermes_dashboard_password}
      HERMES_DASHBOARD_BASIC_AUTH_SECRET=${config.sops.placeholder.hermes_dashboard_session_secret}
      MATRIX_HOMESERVER=${matrixHomeserver}
      MATRIX_USER_ID=${matrixUserId}
      MATRIX_PASSWORD=${config.sops.placeholder.hermes_bot_password}
      MATRIX_DEVICE_ID=rk1b-hermes
      MATRIX_ALLOWED_USERS=@${matrixAdminLocalpart}:${matrixServerName}
      MATRIX_E2EE_MODE=off
    '';

    # ⚠ NO `MATRIX_HOME_ROOM`, AND THAT IS THE DESIGN. It is the plugin's
    # `cron_deliver_env_var`: the room a bare `--deliver matrix` (and an `origin`
    # fallback, since matrix is first in `_HOME_TARGET_PRIORITY`) posts into. Leaving it
    # unset forces every job to NAME its room — `--deliver matrix:!room:server` — which
    # is what keeps routine output out of #infra-alerts by construction rather than by
    # remembering.
    #
    # It also avoids pinning a room id at build time, which is the one thing this could
    # not do safely: a room id is minted by the homeserver and dies with a
    # `matrix-reset`, and an ALIAS cannot stand in for it — the adapter hands the string
    # straight to `send_message_event(RoomID(chat_id))`, i.e. `PUT /rooms/{id}/send/…`,
    # and resolves no alias anywhere (there is no `/directory/room/` call in the plugin
    # at all). A sops-pinned id is the same build-time constant a reset silently
    # invalidated for #infra-alerts. So the id lives in kelpy's marker
    # (`/var/lib/matrix-hermes-rooms/<job>.room-id`) and reaches the job through
    # `hermes cron update`, which is where jobs live anyway.
    #
    # E2EE is OFF rather than optional: the per-job rooms are created unencrypted, so
    # the only thing an olm session would add here is a device to verify and a crypto
    # store to lose.
    #
    # ⚠ ROTATING THE PASSWORD NEEDS A MANUAL RESTART, for the same reason the dashboard
    # credentials do — see restartTriggers below.

    # Pin the uid/gid. Otherwise auto-allocated, they get reshuffled by a reboot that
    # re-derives the system-user map, which orphans /var/lib/hermes (its sqlite ends up
    # owned by another service's id) and crash-loops the gateway. The upstream module
    # creates the user; only the numbers here are ours.
    #
    # ⚠ NOT openclaw's old 989/987. Those were never deployed, and gid 987 ALREADY BELONGS
    # to git-annex (hosts/rk1/git-annex.nix) — a latent collision that stayed invisible
    # only because openclaw was enabled on no host. `nix flake check` catches it the moment
    # anything lands them on one machine (`trace: Duplicate gid 987`). On rk1b every gid
    # from 977 up is taken, so this pair comes from below that block: 968-976 is unclaimed
    # on every host and by every pin in this repo.
    users.users.hermes.uid = 976;
    users.groups.hermes.gid = 976;

    services.hermes-agent = {
      enable = true;
      environmentFiles = [ config.sops.templates."hermes-env".path ];

      # ── WHAT THE AGENT'S SHELL CAN REACH ────────────────────────────────────────────
      # Upstream's own knob for this ("More packages on the PATH of the agent"), used in
      # preference to `systemd.services.hermes-agent.path` because the module already
      # defines the unit's PATH and the two would fight over one option.
      #
      # The unit PATH ships bash, git, coreutils, findutils, grep and sed and NOTHING
      # ELSE — in particular no interpreter at all, so an agent asked to run a script had
      # no way to. Note hermes is itself a Python application: its own interpreter is
      # inside the package closure and is NOT on the agent's PATH, so `python3` here is a
      # real addition rather than a name for something already reachable.
      #
      # `python3` is the bare interpreter. `python3 -m venv` works for a throwaway
      # environment; library sets belong in a `python3.withPackages` here rather than in
      # anything the agent pip-installs at runtime, which would not survive a restart.
      extraPackages = with pkgs; [
        python3
        nodejs
        # The instruction file below tells the agent to reach for `nix shell` for anything
        # it does not have. That advice is only actionable if `nix` itself is on the PATH,
        # and it is not there by default — the agent would read the rule, try it, and get
        # "nix: command not found".
        nix
      ];

      # ── WHAT THE AGENT IS TOLD ──────────────────────────────────────────────────────
      # Upstream's own option for workspace context, which its description names AGENTS.md
      # as the case for. The file is the FLEET'S rule about reaching for tools, shared
      # verbatim with opencode (profiles/opencode.nix) from one source — the model
      # catalogue already taught this repo what two hand-kept copies of the same fact do.
      #
      # Deliberately only the tools rule here. opencode is handed a longer file because it
      # edits repositories and needs the commit conventions; hermes runs scheduled jobs
      # against the fleet and does not.
      documents."AGENTS.md" = ./agent-instructions/nix-tools.md;

      # Set explicitly because `documents` installs RELATIVE to it, and upstream warns that
      # its default differs per module — leaving it unset would place the file in a
      # directory nobody chose. This is the value the module already uses here; naming it
      # makes the two agree by construction rather than by coincidence.
      workingDirectory = "/var/lib/hermes/workspace";

      # Share HERMES_HOME with interactive shells, because CRON JOBS ARE NOT DECLARATIVE:
      # they live in jobs.json under the state dir and are created with the `hermes` CLI or
      # the dashboard. Without this an operator who sshes in gets a second, empty ~/.hermes
      # and would wonder where the schedule went.
      addToSystemPackages = true;

      settings = {
        model = {
          # `custom` is Hermes's generic OpenAI-compatible path (aliases: ollama, vllm,
          # llamacpp). Pointing it at our own LiteLLM is what lets this host run a rented
          # self-hostable model today and a locally-served one later with NO change here —
          # only the gateway's model_list moves. That is the whole measurement design.
          provider = "custom";
          base_url = "http://${litellmHost}:${toString litellm.port}/v1";
          default = "qwen3.8-27b";

          # ⚠ WITHOUT THIS EVERY REQUEST GOES OUT AS `Authorization: Bearer no-key-required`
          # AND LITELLM 400s. A bare `provider: custom` is assumed to be a KEYLESS LOCAL
          # SERVER (ollama, llama.cpp), so hermes substitutes that literal placeholder; the
          # credential is only picked up when a config block NAMES the variable holding it
          # (`runtime_provider_custom._key_env_secret`). Having CUSTOM_API_KEY exported is
          # not enough, which is what makes this one hard to see.
          #
          # The failure also lands a long way from its cause. LiteLLM rejects the
          # placeholder in `user_api_key_auth`, where a non-master key means a database
          # lookup — and this proxy has no database — so what reaches the user is
          # `HTTP 400: No connected db`, which reads like a LiteLLM fault rather than a
          # missing credential. Found by capturing the loopback request: the wire said
          # `Bearer no-key-required` while the key sat correct in the environment.
          key_env = "CUSTOM_API_KEY";
        };

        # ── OPERATOR SKILLS, BESIDE THE AGENT'S OWN RATHER THAN ON TOP OF THEM ─────────
        # `external_dirs` is the READ side of upstream's skills seam; `create_dir` (and the
        # default `$HERMES_HOME/skills/`) is the WRITE side, where hermes creates skills from
        # experience and improves them during use. That learning loop is the product, so the
        # fleet declares beside it and never into it — a skill declared into `skills/` would
        # be overwritten on every activation, taking the agent's own work with it.
        #
        # A store path makes the read-only half true by construction rather than by promise.
        # Empty today; the directory exists so an operator-authored skill has an obvious home
        # that is reviewed in a diff. See ADR-0041.
        skills.external_dirs = [ "${./agent-skills}" ];

        # ── THE MODEL PICKER, WHICH IS A SEPARATE CREDENTIAL PATH ──────────────────────
        # `model` above settles what a session TALKS to; this settles what the dashboard
        # OFFERS. They do not share a code path: with only the block above, the picker
        # showed exactly one entry (`total_models: 1, source: model-config`, the configured
        # default) because its catalogue fetch hit /v1/models UNAUTHENTICATED — 401 — and
        # fell back to listing what was statically configured.
        #
        # A `providers:` entry carries its own `key_env`, which the catalogue fetch does
        # honour. With it the picker lists all six models and reports `source: user-config`,
        # and the live fetch now works well enough to turn up `whisper`, which is not named
        # here at all.
        #
        # DERIVED from `settings.models`, the one catalogue the gateway and both agents
        # share — this list used to be hand-written here and in opencode, and the two
        # disagreed within a day. `chat` is the filter: `whisper` is routable but
        # transcribes audio, so offering it as a session model would offer a session that
        # cannot answer.
        providers.litellm = {
          name = "LiteLLM";
          base_url = "http://${litellmHost}:${toString litellm.port}/v1";
          key_env = "CUSTOM_API_KEY";
          models = lib.mapAttrs (_: _: { }) chatModels;
        };

        # Catch up a recurring job missed while the host was down, matching `Persistent =
        # true` on every systemd timer in this fleet.
        cron.catch_up_missed = true;

        # The name the operator's browser actually types, which Caddy passes through
        # unchanged. The backend's DNS-rebinding guard rejects every Host header that is
        # not the address it bound to UNLESS the name is declared here, so without this
        # line the vhost answers 400 on every request while the service itself is fine.
        dashboard.public_url = publicUrl;
      };

      backend = {
        # The admin panel plus the /api/ws socket, bound to THIS HOST'S TAILSCALE ADDRESS so
        # kelpy's Caddy can reach it (settings.services.private.agent). Until 2026-11-13 it
        # was loopback-only and reached over an SSH tunnel.
        #
        # ⚠ A NON-LOOPBACK BIND MAKES THE AUTH GATE MANDATORY, and that is the point rather
        # than a cost. The tailnet guard in front of the vhost cannot be the only control
        # here: this panel carries a PTY on rk1b as the `hermes` user, and the tailnet is
        # not single-person (ADR-0027). Upstream reached the same conclusion the hard way —
        # `--insecure` still parses but has been IGNORED since their June 2026 incident
        # (`should_require_auth` in web_server_boundary.py), so there is no way to bind off
        # loopback without credentials even if one wanted it. They come from sops above.
        mode = "dashboard";
        inherit (svc) port;

        # NOT `host = "0.0.0.0"`, which litellm and immich use next door. Two reasons, and
        # both are specific to this service rather than stylistic:
        #
        #   1. A wildcard bind DISABLES the Host check outright (`_is_accepted_host` returns
        #      true for any header when bound to 0.0.0.0, "no protection possible at this
        #      layer"). Binding the tailnet address keeps the guard meaningful, so the only
        #      names that work are the vhost declared above and the address itself.
        #   2. It would also answer on rk1b's LAN interface, where the firewall rule below
        #      is the sole thing standing in the way.
        #
        # The address is not known at build time and tailscaled may not have brought it up
        # when the unit starts, so `waitFor` polls the interface and binds what it finds —
        # upstream's option for exactly this, in preference to losing the race and relying on
        # `Restart=on-failure` to paper over it. It stops rather than falling back to a wider
        # address, which is the behaviour to want here.
        waitFor = "interface";
        interfaceName = "tailscale0";
      };
    };

    # ── THE SAME RULE AT $HOME, BECAUSE AGENTS.md IS READ FROM THE CWD ─────────────────
    # `documents` above puts it in the WORKING DIRECTORY, which covers everything that runs
    # itself: cron jobs and dashboard sessions all start at `terminal.cwd`. Measured — a
    # turn started there quotes the rule back and runs `nix shell`; the same turn started
    # anywhere else answers "there is no AGENTS.md in my context" and reports the tool
    # missing instead.
    #
    # The one path that misses it is a person: `sudo -u hermes -H hermes …` starts in this
    # user's HOME, not the workspace. So the file goes there too — the SAME store path, so
    # there is one source and nothing to drift, and a symlink rather than a copy so that
    # stays true.
    #
    # ⚠ NOT SOUL.md, WHICH WOULD HAVE BEEN UNCONDITIONAL AND COST MORE. Hermes auto-upgrades
    # SOUL.md only while it byte-matches a known template (`is_legacy_template_soul`), so
    # appending one line would freeze the persona against every future upstream revision —
    # and declaring it would rewrite it on every activation, stomping any edit made from the
    # dashboard. A narrow gap is not worth owning that file.
    #
    # The existing hermes-state-dirs guard applies these rules before every unit start,
    # which is also what gets them past the impermanence bind mount (see its comment).
    systemd.tmpfiles.rules = [
      "L+ ${hermesStateDir}/AGENTS.md - - - - ${./agent-instructions/nix-tools.md}"
    ];

    # Tailscale peers only — NOT `networking.firewall.allowedTCPPorts`, which would also
    # publish the panel on rk1b's LAN interface. Note this is belt-and-braces on a host
    # whose `trustedInterfaces` already includes tailscale0: the rule is what keeps the
    # port closed should that ever be narrowed, and it states the intent where the bind is.
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ svc.port ];

    # The module writes config.yaml and .env from an ACTIVATION SCRIPT, which does not
    # restart the service when they change — so a deploy would update the config on disk and
    # leave the gateway running the previous one (a repointed model or a changed base_url
    # staying unknown until a manual restart). The retired openclaw profile hit exactly this
    # trap; the fix carries over. Only `settings` is hashed, deliberately: the rendered env
    # holds the LiteLLM key and a restartTrigger lands in a world-readable unit file.
    #
    # BOTH UNITS, because config.yaml is not only the gateway's. `dashboard.public_url`
    # lives in the same file and is read by the BACKEND at startup, and it is the one value
    # whose staleness is invisible from this end: the vhost would answer 400 on every
    # request ("Invalid Host header") while the unit sat there green. The backend's bind
    # arrives on its command line instead, so that half restarts on its own — which is
    # exactly why this is easy to miss.
    systemd.services.hermes-agent.restartTriggers = [
      (builtins.toJSON config.services.hermes-agent.settings)
    ];
    systemd.services.hermes-backend.restartTriggers = [
      (builtins.toJSON config.services.hermes-agent.settings)
    ];

    # ── THE STATE DIRECTORIES HAVE TO EXIST BEFORE THE UNITS CHDIR INTO THEM ───────────────
    # Both units set `WorkingDirectory=/var/lib/hermes/workspace`, and systemd applies that
    # to ExecStartPre as well — so if the directory is missing the unit does not start
    # degraded, it dies at step CHDIR before running a single line:
    #
    #   hermes-agent.service: Changing to the requested working directory failed:
    #     No such file or directory
    #   hermes-agent.service: Failed at step CHDIR spawning …-hermes-agent-pre-start
    #
    # Which is exactly what happened on rk1b on 2026-11-11, on the FIRST activation that
    # carried this profile: both units crash-looped on arrival and stayed down.
    #
    # ⚠ THE UPSTREAM UNIT ALREADY ORDERS ITSELF `After=systemd-tmpfiles-setup.service`, and
    # that is not enough, which is the whole subtlety. On this host /var/lib/hermes is an
    # IMPERMANENCE BIND MOUNT over /persistent/var/lib/hermes, and the sequence on a first
    # deploy is:
    #
    #   1. boot: systemd-tmpfiles-setup runs — the mount does not exist yet, so the rules
    #      land on the tmpfs root, where nothing will ever look for them;
    #   2. switch: var-lib-hermes.mount is created and mounts an EMPTY persistent directory
    #      over the top, hiding whatever step 1 made;
    #   3. switch: the hermes units start. `After=systemd-tmpfiles-setup` is satisfied
    #      INSTANTLY — that unit has been active since boot — and NixOS's switch-time
    #      equivalent, systemd-tmpfiles-resetup.service, is nothing the unit knows about.
    #
    # A plain reboot does not show this: there the mount is a local-fs unit ordered before
    # local-fs.target, and tmpfiles-setup runs after it. Only the activation path is broken,
    # which is why it survived until the first host actually deployed the profile.
    #
    # So make it a PRECONDITION rather than an ordering hope. `Requires=` + `After=` on a
    # oneshot that is not RemainAfterExit means it runs before EVERY start of either unit,
    # including a bare `systemctl start hermes-agent` months later with the directory gone.
    # It costs milliseconds and it cannot drift from the real rules, because it applies the
    # module's OWN tmpfiles declarations rather than restating their paths, modes and owner.
    systemd.services.hermes-state-dirs = {
      description = "Create Hermes' state directories before the agent chdirs into them";
      # The directories only mean anything once the persistent bind mount is in place —
      # creating them on the tmpfs root underneath it is precisely step 1's mistake.
      unitConfig.RequiresMountsFor = [ "/var/lib/hermes" ];
      # ── AND THE SOPS-RENDERED .env HAS TO BE CURRENT BEFORE THEY READ IT ───────────────
      # Second ExecStart below, and it fixes a silent one-deploy lag that cost this profile
      # its first attempt at the vhost (2026-11-13): the dashboard came up refusing to bind
      # — "the auth gate engages on non-loopback binds, but no auth providers are
      # registered" — while the credentials sat correctly rendered in /run/secrets.
      #
      # Upstream writes $HERMES_HOME/.env from its ACTIVATION SCRIPT, and it knows about this
      # hazard: `hermes-agent-setup` is `stringAfter [ "users" ] ++ optional (activationScripts
      # ? setupSecrets) "setupSecrets"`. But this fleet sets `sops.useSystemdActivation`
      # (profiles/sops.nix), so there IS no `setupSecrets` activation script — sops renders
      # from a UNIT instead, which starts after every activation script has run. The
      # `optional` then contributes nothing and the guard evaporates with no warning. So
      # activation copies the PREVIOUS .env, and the new secret only lands one deploy later.
      #
      # Re-running the activation snippet from a unit ordered after sops closes it. It runs
      # upstream's own text rather than a hand-copied `install` of the env file, for the same
      # reason the tmpfiles call above does: no second copy of the rules to drift. The snippet
      # is idempotent — it is what every `nixos-rebuild switch` already runs — and the
      # config.yaml half of it is a merge that keeps the keys Nix does not own.
      after = [ "sops-install-secrets.service" ];
      serviceConfig = {
        Type = "oneshot";
        # Deliberately NOT RemainAfterExit: as a one-shot that goes inactive on success, a
        # `Requires=` from the units below re-runs it on every start, so this is a guard
        # rather than a one-time bootstrap.
        ExecStart = [
          "${config.systemd.package}/bin/systemd-tmpfiles --create --prefix=/var/lib/hermes"
          (pkgs.writeShellScript "hermes-agent-setup-rerun" ''
            set -eu
            ${config.system.activationScripts."hermes-agent-setup".text}
          '')
        ];
      };
    };

    systemd.services.hermes-agent.requires = [ "hermes-state-dirs.service" ];
    systemd.services.hermes-agent.after = [ "hermes-state-dirs.service" ];
    systemd.services.hermes-backend.requires = [ "hermes-state-dirs.service" ];
    systemd.services.hermes-backend.after = [ "hermes-state-dirs.service" ];

    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [ "/var/lib/hermes" ];
    };
  };
}
