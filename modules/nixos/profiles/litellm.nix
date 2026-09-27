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
