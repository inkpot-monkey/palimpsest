{
  config,
  lib,
  settings,
  self,
  ...
}:

let
  cfg = config.custom.profiles.litellm;
in
{
  options.custom.profiles.litellm = {
    enable = lib.mkEnableOption "LiteLLM proxy configuration";
  };

  config = lib.mkIf cfg.enable {
    sops.templates."litellm-env".content = ''
      DEEPINFRA_API_KEY=${config.sops.placeholder."apikey@api.deepinfra.com"}
      LITELLM_MASTER_KEY=${config.sops.placeholder.litellm_key}
    '';

    sops.secrets = {
      "apikey@api.deepinfra.com" = {
        sopsFile = self.lib.getSecretPath "profiles/ai.yaml";
      };
      litellm_key = {
        sopsFile = self.lib.getSecretPath "profiles/ai.yaml";
        key = "litellm-key";
      };
    };

    services.litellm = {
      enable = true;
      environmentFile = config.sops.templates."litellm-env".path;
      host = "127.0.0.1";
      inherit (settings.services.private.litellm) port;

      settings = {
        master_key = "os.environ/LITELLM_MASTER_KEY";
        model_list = [
          {
            model_name = "gemini-pro";
            litellm_params = {
              model = "deepinfra/google/gemini-2.5-pro";
              api_key = "os.environ/DEEPINFRA_API_KEY";
            };
          }
          {
            model_name = "gemini-flash";
            litellm_params = {
              model = "deepinfra/google/gemini-2.5-flash";
              api_key = "os.environ/DEEPINFRA_API_KEY";
            };
          }
          {
            model_name = "claude-4-sonnet";
            litellm_params = {
              model = "deepinfra/anthropic/claude-4-sonnet";
              api_key = "os.environ/DEEPINFRA_API_KEY";
            };
          }
          {
            model_name = "deepseek-flash";
            litellm_params = {
              model = "deepinfra/deepseek-ai/DeepSeek-V4-Flash";
              api_key = "os.environ/DEEPINFRA_API_KEY";
            };
          }
          {
            model_name = "deepseek-pro";
            litellm_params = {
              model = "deepinfra/deepseek-ai/DeepSeek-V4-Pro";
              api_key = "os.environ/DEEPINFRA_API_KEY";
            };
          }
          {
            model_name = "minimax";
            litellm_params = {
              model = "deepinfra/MiniMaxAI/MiniMax-M2.5";
              api_key = "os.environ/DEEPINFRA_API_KEY";
            };
          }
          {
            model_name = "qwen3-coder";
            litellm_params = {
              model = "deepinfra/Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo";
              api_key = "os.environ/DEEPINFRA_API_KEY";
            };
          }
          # Local model served by Turing Pi RK1 node rk1a (over tailscale): the general MoE
          # (Qwen3.6-35B-A3B). rk1b was repurposed as the Home Assistant voice node, so it no
          # longer serves a coder model — the only local LLM is now qwen-general on rk1a. The
          # cloud coder remains available as `qwen3-coder` (DeepInfra) above.
          # Generous timeout: CPU MoE decode is ~6-8 tok/s, so a long answer can take minutes.
          {
            model_name = "qwen-general";
            litellm_params = {
              model = "openai/qwen3.6-35b-a3b";
              api_base = "http://rk1a.${settings.tailnet}:8080/v1";
              api_key = "none";
              # Background-agent use: a cold agentic prefill (5-10K tok @ ~9.5 tok/s) can
              # exceed 10 min, so allow up to 30 min per request.
              timeout = 1800;
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

        # Graceful degradation: if rk1a (the sole local LLM node) is down or mid model-swap,
        # fail over to DeepInfra once it's funded again (currently 402 / no balance). The local
        # cross-node fallback is gone because rk1b no longer serves a model (it's the voice node).
        litellm_settings.fallbacks = [
          {
            "qwen-general" = [
              "qwen3-coder"
              "deepseek-flash"
            ];
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
