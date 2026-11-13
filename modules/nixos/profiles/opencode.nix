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
# This is the first build on palimpsest#118's map, which is otherwise plan-only. Two of
# its open tickets were settled by the operator to get here, and they are recorded at the
# config below rather than in a comment that would drift from it: the provider (#129) and
# the permission policy (#128). The rest of the map is still open — in particular #159
# (which filesystem holds the server-side trees) and #158 (what an rk1b restart is allowed
# to destroy), so the state layout below is deliberately the smallest thing that works and
# should be revisited when those land.
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

  stateDir = "/var/lib/opencode";

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
    # What is set now is the map's original charted target — auto-approve edits inside the
    # tree, prompt on the rest — with the honest caveat that "prompt on the rest" is
    # aspirational for `bash` until the enforcement path is seen working. Re-measure with
    # the probe above before relying on it; if it still does not fire, the real control is
    # the one below the agent, not this key: the `opencode` user's own privileges.
    #
    # ⚠ `bash` IS SPELLED `bash` HERE AND BECOMES ACTION `shell` INTERNALLY. Confirmed with
    # `opencode debug config`, which is the only way to see what a config actually parsed
    # to — it reports `{action: shell, resource: "*", effect: ask}`. Worth re-running after
    # any schema bump; a key this file spells wrong is silently dropped, not rejected.
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
    model = "litellm/sonnet-5.5";
  };
in
{
  options.custom.profiles.opencode = {
    enable = lib.mkEnableOption "opencode server-side agent sessions";
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

    sops.templates."opencode-env".content = ''
      OPENCODE_SERVER_PASSWORD=${config.sops.placeholder.opencode_server_password}
      LITELLM_KEY=${config.sops.placeholder.litellm_key}
    '';

    # Pin the uid/gid for the same reason hermes does: an auto-allocated pair gets
    # reshuffled by a reboot that re-derives the system-user map, which orphans the state
    # directory. 975 is the next free number below hermes' 976 on every host in the fleet.
    users.users.opencode = {
      isSystemUser = true;
      group = "opencode";
      uid = 975;
      home = stateDir;
      createHome = true;

      # ⚠ A REAL SHELL, AND NOT THE SYSTEM-USER DEFAULT. `isSystemUser` leaves `shell`
      # at nologin, and opencode runs every bash tool call through the user's LOGIN
      # SHELL — so nologin does exactly what it is built to do and prints
      #
      #   This account is currently not available.
      #
      # back to the agent, for every command it tries. Nothing fails at deploy or at
      # startup: the service is green and only the tool calls are dead, which is why
      # this surfaces as an agent that cannot do anything rather than as an error.
      shell = pkgs.bashInteractive;
    };
    users.groups.opencode.gid = 975;

    systemd.services.opencode = {
      description = "opencode server-side agent sessions";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      wants = [ "network-online.target" ];

      environment = {
        HOME = stateDir;
        # opencode reads its state, config and cache from the XDG dirs; pinning them keeps
        # everything that must survive a restart inside the one persisted directory.
        XDG_DATA_HOME = "${stateDir}/share";
        XDG_CONFIG_HOME = "${stateDir}/config";
        XDG_CACHE_HOME = "${stateDir}/cache";
        XDG_STATE_HOME = "${stateDir}/state";
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
      ];

      serviceConfig = {
        User = "opencode";
        Group = "opencode";
        StateDirectory = "opencode";
        WorkingDirectory = stateDir;
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

    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [ stateDir ];
    };
  };
}
