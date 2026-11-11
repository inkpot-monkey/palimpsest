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
  options.custom.profiles.litellm = {
    enable = lib.mkEnableOption "LiteLLM proxy configuration";
  };

  config = lib.mkIf cfg.enable {
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

        # MEASUREMENT MONTH (started 2026-11-10). Exactly TWO open models, one per hardware
        # tier under consideration, so a month of real traffic answers three questions that
        # benchmarks cannot: what would owning this have cost, would the output have been
        # good enough, and does the bigger box buy anything.
        #
        #   qwen3.8-27b             → the ~32 GB GPU  (20.88 GB at Q5_K_XL)
        #   nemotron-3.5-super-vl   → the 128 GB box  (86.91 GB at Q4_K_XL)
        #
        # Deliberately absent: DeepSeek-V4, GLM-5.3, Kimi K3, MiniMax, Qwen3-Coder-480B.
        # They are better models, and renting one would invalidate the experiment, because
        # no home box can run them. OpenRouter is the ONLY external provider here besides
        # Anthropic, by choice — it reaches both tiers under one account, takes no markup on
        # inference, and alone lets the quantization be pinned per request. Lyceum was
        # evaluated and rejected: 10x the input price on the one model both carry ($0.40 vs
        # $0.039 per M) and it lacks the model it was considered for.
        #
        # Two validity caveats to remember when reading the results. No provider serves
        # GGUF, so each entry pins the served tier nearest the quant we would run — fp8 for
        # the 27B, nvfp4 for Nemotron — making quality here an UPPER bound, tighter for
        # Nemotron than for the 27B. And this cannot measure prefill latency at all: a
        # provider's datacentre GPU is not our card, and prefill is the main hardware risk.
        model_list = [
          # Qwen3.8-27B (dense, 27B, Apache 2.0). UD-Q5_K_XL = 20.88 GB, the quality knee;
          # the most-downloaded model on the Hub and the one practitioners actually name.
          # The `provider` block is what makes the rent a fair proxy for the self-host:
          # fp8 only, no silent fallback to a cheaper quant, zero data retention, and
          # require_parameters so an endpoint that cannot do tool calls is skipped rather
          # than quietly dropping them.
          {
            model_name = "qwen3.8-27b";
            litellm_params = {
              model = "openrouter/qwen/qwen3.8-27b";
              api_key = "os.environ/OPENROUTER_API_KEY";
              extra_body.provider = {
                # The quant pin is the experiment's validity constraint and is NOT
                # negotiable. Fallbacks are ALLOWED but only within that pinned pool, so a
                # busy provider is routed around rather than failing the call. That
                # distinction matters more than it looks: with fallbacks off, a measured
                # upstream 429 fired openclaw's Sonnet fallback — which would have recorded
                # "the open model failed the task" when the truth was "a provider was
                # rate-limited", quietly poisoning the one number this month exists to
                # produce. Ten fp8 endpoints serve this model (Chutes, Near AI, Wafer,
                # PrimeIntellect, Mancer, Tenstorrent, Reka, AkashML, Parasail, CoreWeave),
                # so the pool is deep. `require_parameters` also earns its place: CoreWeave
                # and SiliconFlow advertise some models without tool support and are
                # excluded automatically rather than silently dropping tool calls.
                quantizations = [ "fp8" ];
                allow_fallbacks = true;
                require_parameters = true;
                data_collection = "deny";
                zdr = true;
              };
            };
          }
          # THE 128 GB TIER. Nemotron 3.5 Super VL, 120B total / 12B active, OpenMDW-1.1.
          # UD-Q4_K_XL = 86.91 GB, which is the point: it does NOT fit 32 GB, so it is the
          # only thing here that actually distinguishes the two boxes. nvfp4 is pinned
          # rather than fp8 because 4-bit is the tier closest to the ~4.2 bits/weight we
          # would run locally — BETTER validity than the 27B above, not worse.
          #
          # Read this one as a FLOOR for the tier, not a ceiling. The model a 128 GB owner
          # would really run is Qwen3.8-Flash-Next (24 of 95 Strix-Halo HN comments; next
          # best is 7), and on NVIDIA's OWN published numbers Nemotron loses to it badly:
          # SWE-bench Pro 51.78 vs 60.37, Terminal-Bench 2.1 60.67 vs 85.80. Flash-Next is
          # effectively unrentable — not served per-token by DeepInfra, Together, Novita,
          # Nebius, SiliconFlow, Parasail, Chutes, DashScope, Hyperbolic, Baseten or
          # OpenRouter; Fireworks lists it dedicated-GPU-only; and Lyceum, reported as the
          # one per-token source, does NOT carry it — its catalogue has 12 models and the
          # "$0.20/$0.50" attributed to Flash-Next is GLM-5.3-Flash's price, verified on
          # Lyceum's own pricing page. Beware the near-miss generally: `qwen3.8-flash` is
          # Alibaba's separate MANAGED SKU, not this architecture, and several providers
          # resell it while quoting Flash-Next's spec sheet.
          #
          # So the honest reading of a month of data: if Nemotron measures no better than
          # the 27B above, that is evidence the 128 GB tier buys nothing — note its
          # SWE-bench Pro 51.78 roughly equals Muse-Glimmer-30B's 51.2 at 15.88 GB. If it
          # measures clearly better, the tier is worth a second look with a real engine,
          # because Flash-Next would beat this.
          {
            model_name = "nemotron-3.5-super-vl";
            litellm_params = {
              model = "openrouter/nvidia/nemotron-3.5-super-vl";
              api_key = "os.environ/OPENROUTER_API_KEY";
              extra_body.provider = {
                quantizations = [ "nvfp4" ];
                allow_fallbacks = true;
                require_parameters = true;
                data_collection = "deny";
                zdr = true;
              };
            };
          }

          # An EU-pinned route for the nightly log review (OVHcloud, Gravelines-only, no
          # prompt retention) was considered and DROPPED: ~EUR 7.46/mo against ~EUR 1.58
          # for the same model via OpenRouter, to keep fleet-log prompts inside France.
          # Judged not worth the split for a one-month experiment. Note what that concedes
          # — for this month the nightly review ships hostnames, IPs and service topology
          # to whichever fp8 provider OpenRouter picks. `zdr` and `data_collection = deny`
          # above constrain retention but not geography. Revisit if the measurement ends
          # in "keep renting" rather than "buy the box", because then it is permanent.

          # The baseline to beat. Routed direct now rather than through DeepInfra, and
          # split by job so the comparison is honest: Haiku is the right tool for the
          # nightly summarisation, Sonnet for agents, Opus only where it earns 2x.
          {
            model_name = "haiku-5.5";
            litellm_params = {
              model = "anthropic/claude-haiku-5-5";
              api_key = "os.environ/ANTHROPIC_API_KEY";
            };
          }
          {
            model_name = "sonnet-5.5";
            litellm_params = {
              model = "anthropic/claude-sonnet-5-5";
              api_key = "os.environ/ANTHROPIC_API_KEY";
            };
          }
          {
            model_name = "opus-5.5";
            litellm_params = {
              model = "anthropic/claude-opus-5-5";
              api_key = "os.environ/ANTHROPIC_API_KEY";
            };
          }
          {
            model_name = "whisper";
            litellm_params = {
              model = "deepinfra/openai/whisper-large-v3";
              api_key = "os.environ/DEEPINFRA_API_KEY";
            };
            model_info = {
              mode = "audio_transcription";
            };
          }
        ];
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
