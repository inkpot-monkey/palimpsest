{
  config,
  lib,
  settings,
  self,
  ...
}:

let
  cfg = config.custom.profiles.litellm;
  svc = settings.services.private.litellm;

  # Same edge/origin split as immich: on the edge Caddy is local and loopback is
  # right; off it, Caddy has to reach in over the tailnet. Derived from the
  # registry so the binding cannot drift from the placement.
  offEdge = (svc.origin or null) == config.networking.hostName;
in
{
  imports = [
    # Declares `levelFromMessage`/`demoteToDebug`, which this profile sets below. Imported
    # rather than assumed: a VM test imports this profile without the monitoring client,
    # and a definition for an option nobody declared is an eval error.
    ./monitoring/log-levels.nix
  ];

  options.custom.profiles.litellm = {
    enable = lib.mkEnableOption "LiteLLM proxy configuration";
  };

  config = lib.mkIf cfg.enable {
    # LiteLLM's proxy logger. Note this unit emits TWO formats: this one, and uvicorn's bare
    # `INFO:     <addr> - "GET /metrics/"` access line, which is deliberately not matched —
    # it is already `info` and it is one line per scrape.
    custom.profiles.monitoring-client.levelFromMessage."litellm.service" =
      self.lib.logLevelPatterns.litellm;

    sops.templates."litellm-env".content = ''
      DEEPINFRA_API_KEY=${config.sops.placeholder."apikey@api.deepinfra.com"}
      OPENROUTER_API_KEY=${config.sops.placeholder."apikey@api.openrouter.ai"}
      ANTHROPIC_API_KEY=${config.sops.placeholder."apikey@api.anthropic.com"}
      LITELLM_MASTER_KEY=${config.sops.placeholder.litellm_key}
    '';

    sops.secrets = {
      "apikey@api.deepinfra.com" = {
        sopsFile = self.lib.getSecretPath "profiles/ai.yaml";
      };
      # OpenRouter fronts the self-hostable open models for the measurement month (see
      # the model_list comment below). It reaches all of them under one account, takes no
      # markup on inference, and — the reason it was chosen over DeepInfra, which we
      # already had a key for — it is the only one that lets the quantization be pinned
      # per request, which is what makes renting a fair proxy for self-hosting.
      "apikey@api.openrouter.ai" = {
        sopsFile = self.lib.getSecretPath "profiles/ai.yaml";
      };
      # Direct Anthropic, funded by the Max plan's monthly Console API credit. Replaces
      # the DeepInfra-proxied `claude-4-sonnet`: same vendor, one less intermediary
      # holding the traffic, and a generation newer. Note the credit does NOT cover
      # Claude Code — that still bills against the subscription.
      "apikey@api.anthropic.com" = {
        sopsFile = self.lib.getSecretPath "profiles/ai.yaml";
      };
      litellm_key = {
        sopsFile = self.lib.getSecretPath "profiles/ai.yaml";
        key = "litellm-key";
      };
    };

    # Off-edge only, and on tailscale0 alone — NOT openFirewall, which would also
    # expose the proxy (and therefore the DeepInfra key behind it) to the LAN.
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = lib.mkIf offEdge [ svc.port ];

    services.litellm = {
      enable = true;
      environmentFile = config.sops.templates."litellm-env".path;
      host = if offEdge then "0.0.0.0" else "127.0.0.1";
      inherit (svc) port;

      settings = {
        master_key = "os.environ/LITELLM_MASTER_KEY";

        # Per-request cost and token counters, scraped by the monitoring server that is
        # co-located on this host (monitoring/server.nix adds the `litellm` job). This is
        # the instrument for the measurement month: `litellm_spend_metric` is real money,
        # and `litellm_input_cached_tokens_metric` says whether prompt caching is working
        # — the difference between a cheap month and an expensive one. NOT enterprise-
        # gated in 1.108.0 (no `premium_user` guard in integrations/prometheus.py);
        # re-check on a major bump before trusting the dashboards.
        litellm_settings = {
          callbacks = [ "prometheus" ];

          # /metrics authenticates by default, which silently defeats the whole point: the
          # scrape job returned 401 on every attempt and VictoriaMetrics held the target
          # `down` while the proxy itself served traffic perfectly happily. Nothing alerts
          # on that -- you simply find an empty dashboard a month later. Caught by checking
          # the target after deploying; there is no error on this side to notice.
          #
          # Unauthenticated is the right call here rather than handing Prometheus the
          # master key: the scrape is loopback (monitoring is co-located on rk1b), and it
          # matches how every other exporter in this fleet already works -- node-exporter,
          # gatus and blocky are all open on the tailnet. The cost is that anyone on the
          # tailnet can read spend-by-model through the Caddy vhost, which is not nothing
          # given the tailnet is not single-person (ADR-0027), but it is per-model totals
          # and latencies, never prompts or keys.
          require_auth_for_metrics_endpoint = false;
        };

        # DERIVED from `settings.models` (parts/settings.nix), which is where the catalogue
        # and the reasoning for each entry now live. It is shared with the two agents, who
        # each need the same list of names and used to keep their own copy — see the
        # warning at the registry about the day they disagreed.
        #
        # `whisper` is in here like everything else: `chat` filters what the AGENTS offer,
        # not what this gateway routes. A transcription endpoint still has to be reachable.
        model_list = lib.mapAttrsToList (
          model_name: m:
          {
            inherit model_name;
            inherit (m) litellm_params;
          }
          // lib.optionalAttrs (m ? model_info) { inherit (m) model_info; }
        ) settings.models;
      };
    };

    users.users.litellm = {
      isSystemUser = true;
      group = "litellm";
    };
    users.groups.litellm = { };

    systemd.services.litellm.serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = "litellm";
      Group = "litellm";
    };

    systemd.tmpfiles.rules = [
      "Z /var/lib/litellm 0750 litellm litellm - -"
    ];
  };
}
