{
  config,
  lib,
  inputs,
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

    # NO NEW SECRET. Hermes reads `CUSTOM_API_KEY` for its `custom` (OpenAI-compatible)
    # provider, and the agent authenticates to our OWN LiteLLM with the same master key
    # every other consumer uses — LiteLLM is what holds the upstream vendor keys. So this
    # host never sees an OpenRouter or Anthropic credential.
    sops.templates."hermes-env".content = ''
      CUSTOM_API_KEY=${config.sops.placeholder.litellm_key}
    '';

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
        };

        # Catch up a recurring job missed while the host was down, matching `Persistent =
        # true` on every systemd timer in this fleet.
        cron.catch_up_missed = true;
      };

      backend = {
        # The admin panel plus the /api/ws socket. LOOPBACK ONLY, and that is load-bearing
        # twice over: a non-loopback bind turns on the dashboard's auth gate (which would
        # need another secret), and it also turns on its DNS-rebinding guard, which refuses
        # any request whose Host header differs from the address it bound to — i.e. it would
        # reject a Caddy vhost name. Hence no `settings.services` entry and no vhost; reach
        # it over an SSH tunnel, or use the CLI, which shares this state (above).
        mode = "dashboard";
        host = "127.0.0.1";
      };
    };

    # The module writes config.yaml and .env from an ACTIVATION SCRIPT, which does not
    # restart the service when they change — so a deploy would update the config on disk and
    # leave the gateway running the previous one (a repointed model or a changed base_url
    # staying unknown until a manual restart). The retired openclaw profile hit exactly this
    # trap; the fix carries over. Only `settings` is hashed, deliberately: the rendered env
    # holds the LiteLLM key and a restartTrigger lands in a world-readable unit file.
    systemd.services.hermes-agent.restartTriggers = [
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
      serviceConfig = {
        Type = "oneshot";
        # Deliberately NOT RemainAfterExit: as a one-shot that goes inactive on success, a
        # `Requires=` from the units below re-runs it on every start, so this is a guard
        # rather than a one-time bootstrap.
        ExecStart = "${config.systemd.package}/bin/systemd-tmpfiles --create --prefix=/var/lib/hermes";
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
