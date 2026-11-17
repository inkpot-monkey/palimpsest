{
  config,
  lib,
  pkgs,
  settings,
  self,
  ...
}:

# opencode — the fleet's SERVER-SIDE AGENT SESSIONS (GLOSSARY.md → Agent sessions).
#
# The point of running it here rather than on the laptop is that a session OUTLIVES ITS
# CLIENT: send a command, close the laptop, the work continues on rk1b, and any client —
# the phone browser at chat.<domain>, Emacs, `opencode attach` over ssh — re-syncs to the
# same session afterwards. The working tree is server-side too, which is the half that
# makes it more than a chat window.
#
# This is the second build on palimpsest#118's map. Tickets settled here rather than in a
# comment that would drift from the config: the provider (#129), the permission policy
# (#128), and now #159 — which filesystem holds the server-side trees — answered by the
# persistence block at the bottom: /persistent/home/inkpotmonkey/code, bind-mounted to the
# path the laptop uses for the same repository, because GLOSSARY.md requires one directory
# string to name a tree from every client.
#
# #158 (what an rk1b restart is allowed to destroy) is STILL OPEN, so the backup
# classification in hosts/rk1/backup.nix still errs toward keeping things.
let
  cfg = config.custom.profiles.opencode;

  svc = settings.services.private.chat;

  litellm = settings.services.private.litellm;
  litellmOrigin = litellm.origin or litellm.edge;
  litellmHost =
    if litellmOrigin == config.networking.hostName then
      "127.0.0.1"
    else
      "${litellmOrigin}.${settings.tailnet}";

  # ── WHO THIS RUNS AS, AND WHY IT IS NO LONGER A SYSTEM USER ───────────────────────────
  # Until 2026-11-17 this was a pinned system user (`opencode`, uid 975, home
  # /var/lib/opencode). It now runs as the OPERATOR'S OWN ACCOUNT, which rk1b already binds
  # (hosts/default.nix, `bindUsers { inkpotmonkey = operator; }`), because the point of the
  # move is parity: a server-side session should be able to do what the operator can do at
  # the laptop, against the same tree paths, with the same git identity and the same tools.
  # A confined service user could never have that without re-creating every grant by hand.
  #
  # ⚠ THE ACCOUNT CARRIES `operator`, WHICH IS sudo + containers. That is why
  # `NoNewPrivileges` is set on the unit below: the human keeps sudo over SSH, the SERVICE
  # cannot escalate. Read that setting as load-bearing rather than hardening — it is the
  # only gate left, because `permission.bash = "ask"` is MEASURED NOT TO FIRE (see the
  # permission block above).
  inherit (cfg) user;
  home = config.users.users.${user}.home;

  # The session store, config and cache now sit at the XDG defaults under that home rather
  # than in one pinned /var/lib directory. The old arrangement existed to keep everything
  # survivable inside a single persisted path; the persistence block at the bottom names the
  # three that must survive instead, and `cache` is deliberately not among them.
  dataDir = "${home}/.local/share/opencode";
  stateDir = "${home}/.local/state/opencode";
  configDir = "${home}/.config/opencode";
  # (no `cacheDir` binding: the cache is never referenced here precisely because it is
  # neither pinned nor persisted — see the persistence block at the bottom.)

  # ── WHAT THE AGENT IS TOLD ────────────────────────────────────────────────────────────
  # One file, assembled from two: the fleet's tools rule, shared VERBATIM with hermes
  # (profiles/hermes.nix), plus the parts only this agent needs. Concatenated rather than
  # copied for the reason the model catalogue made concrete — two hand-kept copies of the
  # same fact drift, and nothing fails when they do.
  #
  # opencode gets the longer file because it edits repositories: the commit conventions
  # matter here and are noise for hermes, which runs scheduled jobs against the fleet.
  instructionsFile = pkgs.concatText "opencode-instructions.md" [
    ./agent-instructions/nix-tools.md
    ./agent-instructions/opencode.md
  ];

  # The conversational half of the shared catalogue (parts/settings.nix).
  chatModels = lib.filterAttrs (_: m: m.chat) settings.models;

  # ── THE CONFIG FILE, AND WHY THE KEY IS NOT IN IT ──────────────────────────────────────
  # Rendered into the Nix store and pointed at by OPENCODE_CONFIG, which is read-only and
  # therefore fine HERE — but would NOT be for every credential shape. #129 recorded the
  # trap: `OPENCODE_AUTH_CONTENT` is worse than read-only for OAuth, because token refresh
  # writes to auth.json and the written file is then never read again. An API key against
  # an OpenAI-compatible endpoint never refreshes, so a store-rendered config has nothing
  # to write back and the trap does not apply.
  #
  # The key itself still must not be in the store, which every user can read. opencode
  # substitutes `{env:VAR}` in config values, so the file carries the NAME and the sops
  # env file carries the value. Verified on 2.2.6 by running a real turn with the key only
  # ever in the environment.
  settingsFile = (pkgs.formats.json { }).generate "opencode.json" {
    "$schema" = "https://opencode.ai/config.json";

    # ── #128: THE MAP'S CHARTED TARGET, AFTER PROMPT-ON-EVERYTHING WAS WITHDRAWN ───────
    # Set to prompt-on-everything at first deploy and changed by the operator the same day,
    # 2026-11-13, once a measurement showed what that setting was actually worth here.
    #
    # ⚠ `ask` DID NOT PROMPT FOR A SHELL COMMAND. Measured through the vhost: a session was
    # asked to run `node --version && git --version`, it ran, and the output came back —
    # while `GET /api/session/<id>/permission` stayed EMPTY throughout. Nothing was waiting
    # for an answer and nothing timed out. So the previous setting was not holding anything
    # back; it only read as though it was, which is worse than not claiming it. This is the
    # same shape as #120, where the plugin `permission.ask` hook is declared but never fires.
    #
    # ⚠ RE-MEASURED 2026-11-17 WITH A BETTER INSTRUMENT, AND IT STILL DOES NOT FIRE. The
    # first measurement polled REST, which cannot see tool calls at all: `parts` is not a
    # concept in the HTTP API, and a message read back over `/api/session/<id>/message` is
    # an envelope only. The real channel is the SSE stream the Emacs client consumes —
    # `/api/event?types=…`. Subscribed to `permission.asked`, `session.tool.called` and
    # `session.tool.success` and prompted a session to run `node --version`:
    #
    #   session.tool.input.started → session.tool.called → session.tool.success
    #       "name":"shell"   "command":"node --version"
    #   permission events in the whole log: 0
    #
    # So the command ran, the tool was `shell` BY NAME rather than by inference, and nothing
    # was ever asked. Reproduced on both `qwen3.8-27b` and `nemotron-3.5-super-vl`, so it is
    # the server, not a model that declines to call tools.
    #
    # ⚠ THEREFORE: DO NOT WRITE ANYWHERE THAT THIS AGENT ASKS BEFORE RUNNING COMMANDS. It
    # does not. The policy below is kept, not deleted, because it is the one we want if
    # upstream ever implements enforcement — but the real control is the one BELOW the
    # agent: the account's own privileges, now the operator's, hence `NoNewPrivileges` on
    # the unit and a GitHub PAT scoped to two repositories.
    #
    # ⚠ `bash` IS SPELLED `bash` HERE AND BECOMES ACTION `shell` INTERNALLY — which the
    # event stream above confirms independently (`"name":"shell"`). The previous note said
    # `opencode debug config` was the only way to see what a config parsed to; on 2.2.6
    # that command answers `ClientError: UnexpectedStatus: 500`, both as the service user
    # and with the unit's full environment sourced, so it is no longer a check anyone can
    # run. A key this file spells wrong is still silently dropped rather than rejected.
    permission = {
      edit = "allow";
      bash = "ask";
      webfetch = "ask";
    };

    # ── #129: LITELLM, BECAUSE THE SETTLED ANSWER WAS WITHDRAWN BY THE VENDOR ───────────
    # That ticket resolved as "authenticate directly to Anthropic with the Claude Max
    # subscription over OAuth", and Anthropic then blocked third-party use of Pro/Max OAuth
    # tokens server-side and wrote it into the Consumer Terms. opencode removed the flow.
    # It is a legal boundary, not a technical one, so no pin or fork is a route back.
    #
    # Of the options #129 redrew, this is the one that needed no new credential anywhere:
    # the gateway is already on this host, already holds the vendor keys, and hermes
    # already reaches it the same way. What it does NOT give — and this is the reason the
    # ticket rejected it the first time, still true — is spend attribution or a cap: the
    # proxy has no database, so opencode's usage is indistinguishable from every other
    # consumer of the shared master key.
    provider.litellm = {
      npm = "@ai-sdk/openai-compatible";
      name = "LiteLLM";
      options = {
        baseURL = "http://${litellmHost}:${toString litellm.port}/v1";
        apiKey = "{env:LITELLM_KEY}";
      };
      # DERIVED from `settings.models`, the one catalogue the gateway and both agents
      # share. This list and hermes' were hand-written copies and disagreed within a day:
      # this one was missing `nemotron-3.5-super-vl`, so the picker read as an
      # Anthropic-only provider. Nothing fails when they drift — each agent offers exactly
      # what its own list says — so deriving both is what makes it impossible.
      #
      # `chat` is the filter: `whisper` is routable but transcribes audio, and a session
      # model that cannot hold a conversation is not worth offering.
      models = lib.mapAttrs (_: _: { }) chatModels;
    };
    # ⚠ NOT `sonnet-5.5`, WHICH IS WHAT THIS WAS UNTIL 2026-11-16. The Anthropic account
    # funding the direct route ran out of credit and every session here failed — a default
    # model is a single point of failure for the whole service, and a closed model behind a
    # metered account is the most likely thing to become one. `qwen3.8-27b` is the open
    # model on the measurement-month account, the same default hermes runs, and the Claude
    # models stay one picker click away.
    model = "litellm/qwen3.8-27b";

    # Read at session start. A path rather than inline text, so the rules can be read and
    # reviewed as prose by someone not reading Nix.
    instructions = [ "${instructionsFile}" ];
  };
in
{
  options.custom.profiles.opencode = {
    enable = lib.mkEnableOption "opencode server-side agent sessions";

    user = lib.mkOption {
      type = lib.types.str;
      default = "inkpotmonkey";
      description = ''
        The UNIX account the server runs as, and therefore the account whose home holds the
        session store and whose git identity signs a session's commits.

        Must be an account the host actually binds — the home path is read off
        `users.users.<user>.home`, so a name no host binds is an evaluation error here
        rather than a service that starts and cannot write anything.

        ⚠ NOT a confined service user, deliberately, and this is the one option in the file
        whose default encodes a security judgement rather than a convenience. See the
        `user` binding in the `let` above for why, and note that the account's own
        privileges are the real control once `permission.bash` is understood not to fire.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Reuses the LiteLLM master key, exactly as hermes does — this host already decrypts
    # profiles/ai.yaml for it, so neither the recipient set nor `just sops-recipients`
    # moves. The gateway is what holds the upstream vendor credentials.
    sops.secrets.litellm_key = {
      sopsFile = self.lib.getSecretPath "profiles/ai.yaml";
      key = "litellm-key";
    };

    # ── THE SERVER PASSWORD IS THE REAL ACCESS CONTROL, NOT THE TAILNET GUARD ───────────
    # An opencode session is arbitrary code execution on rk1b with write access to the
    # trees it is pointed at. The tailnet is not single-person (ADR-0027 puts friends on it
    # for music and photos), so the vhost's `internal_only` guard cannot be the only thing
    # in front of this — the same reasoning as the hermes dashboard next door.
    #
    # ⚠ THE USERNAME IS LITERALLY `opencode` AND NOTHING ELSE. Measured against 2.2.6:
    # `/api/*` answers 401 with `WWW-Authenticate: Basic realm="Secure Area"`, and only
    # `opencode:<password>` is accepted — an empty or any other username is refused even
    # with the right password. Worth knowing before debugging a login that "should" work.
    #
    # ⚠ AND THE 401 IS ON `/api/*` ONLY. Every other path serves the SPA shell, 200,
    # unauthenticated — `/`, `/session`, `/config` all return the same HTML. That is not a
    # hole (the shell can do nothing until it calls the API, and POSTs to those paths 405),
    # but it does mean a probe of `/` proves nothing about whether the gate is on. Probe
    # `/api/session` instead.
    sops.secrets.opencode_server_password = {
      sopsFile = self.lib.getSecretPath "profiles/ai.yaml";
      key = "opencode-server-password";
    };

    # ── THE AGENT'S OWN GITHUB CREDENTIAL, AND WHY IT IS NOT THE OPERATOR'S ──────────────
    # A fine-grained PAT scoped to the two repositories rk1b holds trees for, with contents,
    # issues and pull-requests write. It is NOT `machine/api.github.com` out of the vault:
    # that one is the human's, reached through `rbw`, and `rbw` cannot be unlocked
    # unattended — users#51 made the whole GitHub token path gui-only for exactly that
    # reason, and the `gh` wrapper there declines when stderr is not a tty, which is every
    # agent tool call. A headless host therefore needs its own credential in host sops;
    # see also profiles/nixConfig.nix's `github_token`, which exists for the same reason.
    #
    # ⚠ `GH_TOKEN` CARRIES `gh` AND GIT-OVER-HTTPS TOGETHER, so this one variable is the
    # whole credential path and no deploy key or credential helper is needed. It also makes
    # the never-`gh auth login` rule structural rather than remembered: gh refuses
    # `auth login` outright while the variable is set.
    sops.secrets.rk1b_agent_pat = {
      sopsFile = self.lib.getSecretFile "github";
      key = "rk1b_agent_pat";
    };

    sops.templates."opencode-env".content = ''
      OPENCODE_SERVER_PASSWORD=${config.sops.placeholder.opencode_server_password}
      LITELLM_KEY=${config.sops.placeholder.litellm_key}
      GH_TOKEN=${config.sops.placeholder.rk1b_agent_pat}
    '';

    # NO `users.users` BLOCK ANY MORE, and its absence is the change. This profile used to
    # declare a pinned system user; the account is now the operator's, bound by the host
    # (hosts/default.nix). Two things that block carried are therefore someone else's
    # problem now, and both are already handled:
    #   the login shell  opencode runs every bash tool call through the user's LOGIN SHELL,
    #                    which is why the old system user needed `shell = bashInteractive`
    #                    instead of the `isSystemUser` nologin default. A real account has a
    #                    real shell, so the trap is gone rather than moved.
    #   the uid pin      no longer ours to pin: a contract-bound account's uid is the
    #                    host's decision, and it is already stable across reboots.

    systemd.services.opencode = {
      description = "opencode server-side agent sessions";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      wants = [ "network-online.target" ];

      environment = {
        HOME = home;
        # STILL PINNED, BUT NOW AT THE XDG DEFAULTS UNDER THE OPERATOR'S HOME. The previous
        # values forced everything into one /var/lib directory so a single persistence entry
        # covered it; the reason that mattered was that a system user's home was itself a
        # state directory. A real account's home is a real home, and parity with the laptop
        # — the point of the move — means a session finds its state where a session at the
        # laptop would. The three that must survive a reboot are named in the persistence
        # block at the bottom; cache is deliberately not one of them.
        #
        # They are set EXPLICITLY rather than left to opencode's own defaults because a
        # systemd unit inherits no XDG variables at all, and opencode would otherwise fall
        # back to paths relative to an unset HOME.
        XDG_DATA_HOME = "${home}/.local/share";
        XDG_CONFIG_HOME = "${home}/.config";
        XDG_CACHE_HOME = "${home}/.cache";
        XDG_STATE_HOME = "${home}/.local/state";
        OPENCODE_CONFIG = settingsFile;
        # The agent must not update itself underneath a pinned package: a self-written
        # binary would both escape the closure and survive a rollback.
        OPENCODE_DISABLE_AUTOUPDATE = "1";
      };

      # ── WHAT THE AGENT'S SHELL CAN REACH ────────────────────────────────────────────
      # A systemd unit gets a minimal default PATH — coreutils, findutils, grep, sed —
      # and NOT `/run/current-system/sw/bin`, so the fleet's system packages are invisible
      # here even when they are installed. Anything the agent is expected to run has to be
      # named, and named HERE rather than in `environment.systemPackages`: this is a
      # property of what this agent may use, not of what the host offers everyone.
      #
      #   nodejs  asked for directly, and also what opencode's own plugin/MCP machinery
      #           shells out to.
      #   git     opencode's `--worktree` flag and its whole session-on-a-tree model are
      #           git operations; without it the agent can read a repo but not use it.
      #           It IS in /run/current-system/sw/bin, which is precisely why its absence
      #           from the unit is easy to miss.
      path = with pkgs; [
        #   bash    `sh` AND `bash` AS NAMES ON THE PATH, which is not the same thing as the
        #           login shell set on the user above. That one is exec'd by absolute path
        #           out of /etc/passwd; anything that spawns a shell BY NAME resolves it
        #           through this PATH instead — and npm does, for every post-install
        #           script. `/bin/sh` existing on the host does not help, so the symptom is
        #           `npm error spawn sh ENOENT` from a box that obviously has a shell.
        bashInteractive
        nodejs
        #   python3 the bare interpreter, matching what hermes carries. `python3 -m venv`
        #           works for a throwaway environment; a library set belongs in a
        #           `python3.withPackages` here, because anything the agent pip-installs at
        #           runtime lives in its state dir and does not survive a rebuild.
        python3
        git
        #   nix     the instruction file tells the agent to reach for `nix shell` for
        #           anything it does not have, and that advice is inert unless `nix` is
        #           here: it is not on a unit's PATH by default.
        nix
        #   gh      the agent files issues and opens PRs on GitHub, and `gh auth
        #           git-credential` is also what serves GH_TOKEN to git-over-https. This is
        #           `pkgs.gh`, the UNWRAPPED binary, deliberately: the operator's home
        #           carries a `gh` wrapper that reads the token out of the vault
        #           (users/inkpotmonkey/modules/github.nix), and a service has no home-manager
        #           home to provide it. With GH_TOKEN already set the wrapper would exec
        #           straight through to this same binary anyway.
        gh
        #   openssh `git` shells out to `ssh-keygen -Y sign` for every signed commit, and
        #           ssh-keygen is NOT on a unit's default PATH. Without it signing fails per
        #           commit while the service stays green.
        openssh
        #   tea     the private forge's client (profiles/forge-client.nix). ⚠ That profile
        #           installs it via `environment.systemPackages`, i.e. into
        #           /run/current-system/sw/bin — which this unit cannot see, per the note at
        #           the top of this list. Enabling forge-client alone would therefore give a
        #           valid token and `tea: command not found`.
        tea
      ];

      serviceConfig = {
        User = user;
        # The operator's primary group. NOT a private group of our own any more: the files a
        # session writes are the operator's files, and a group nothing else is in would make
        # every tree it touches unreadable to the human over SSH.
        Group = "users";
        WorkingDirectory = home;

        # ⚠ THE ONLY GATE LEFT, AND NOT MERELY HARDENING. The account carries `operator`
        # (sudo + containers), and `permission.bash = "ask"` is measured not to fire — a
        # shell tool call runs with nothing asked. This keeps sudo for the human over SSH
        # while denying the SERVICE any route to escalate. Re-read the permission block
        # above before weakening it.
        NoNewPrivileges = true;

        # NO `StateDirectory` ANY MORE: that managed /var/lib/opencode for the system user
        # this profile no longer declares. State lives under the operator's home (see
        # `environment` above) and survives via the persistence block at the bottom.
        EnvironmentFile = config.sops.templates."opencode-env".path;
        # ⚠ `--hostname 0.0.0.0` AND NOT THE TAILSCALE ADDRESS, unlike hermes next door.
        # There the wildcard would have DISABLED a real defence (its Host-header check
        # treats 0.0.0.0 as "no protection possible"); opencode has no such check, so
        # nothing is given up and this follows the fleet's existing convention for an
        # off-edge service — litellm and immich bind the same way, with the tailscale0-only
        # firewall rule below as the network control and the password as the real one.
        ExecStart = "${pkgs.opencode}/bin/opencode serve --hostname 0.0.0.0 --port ${toString svc.port}";
        Restart = "on-failure";
        RestartSec = "5s";
      };

      # The rendered config is read at startup, so a changed model or permission policy
      # needs the unit restarted to take effect. Hashing the store path is enough — it
      # changes whenever the content does, and it holds no secret (see settingsFile).
      restartTriggers = [ settingsFile ];
    };

    # Tailnet peers only — NOT `allowedTCPPorts`, which would publish a code-execution API
    # on rk1b's LAN interface behind nothing but the password.
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ svc.port ];

    # ── WHAT SURVIVES A REBOOT (palimpsest#159, answered) ─────────────────────────────────
    # rk1b's root is a 2G tmpfs and `/home` is NOT in profiles/impermanence.nix's keep-list,
    # so without this block the operator's home — trees, session store and all — is gone at
    # every boot. hosts/rk1/git-annex.nix hit exactly this and added its own entry for the
    # same reason.
    #
    # ⚠ THE TREES ARE THE ANSWER TO #159, AND THE BIND-MOUNT IS WHY IT WORKS. GLOSSARY.md
    # requires a server-side tree to carry THE SAME PATH as the laptop's tree for the same
    # repository, so one directory string names it from every client. impermanence
    # bind-mounts, so `/persistent/home/inkpotmonkey/code` appears at
    # `/home/inkpotmonkey/code` and that invariant holds literally rather than by
    # convention — while the bytes sit on the NVMe-backed /persistent instead of the tmpfs.
    #
    # `cache` is deliberately absent: model catalogues and downloaded provider packages,
    # re-fetched on demand. hosts/rk1/backup.nix already excluded the old cache path for
    # the same reason, and every directory named here must be classified in that file.
    #
    # NOT listed, and each for a reason worth not re-deriving:
    #   ~/.config/tea   forge-client renders it as a sops template plus a tmpfiles `L+`
    #                   symlink into /run/secrets, explicitly so it survives a tmpfs home by
    #                   being RECREATED rather than kept. Persisting it would pin a stale
    #                   symlink over a self-healing one.
    #   ~/.ssh          the signing key is a sops secret, not a file in the home (ADR-0003's
    #                   dedicated non-admin `signing_key`). What is left is `known_hosts`,
    #                   which is re-acquired on first connect.
    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        {
          directory = "${home}/code";
          inherit user;
          group = "users";
          mode = "0755";
        }
        {
          directory = dataDir;
          inherit user;
          group = "users";
          mode = "0700";
        }
        {
          directory = stateDir;
          inherit user;
          group = "users";
          mode = "0700";
        }
        {
          directory = configDir;
          inherit user;
          group = "users";
          mode = "0700";
        }
      ];
    };
  };
}
