{
  inputs,
  config,
  pkgs,
  self,
  settings,
  ...
}:
{
  imports = [
    inputs.vpsFree.nixosModules.containerUnstable

    self.nixosProfiles.bundle
  ];

  custom.profiles = {
    base.enable = true;
    impermanence.enable = true;
    tailscale = {
      enable = true;
      tags = [ "tag:server" ];
    };
    ssh.enable = true;
    proxy.enable = true;
    backup.enable = true;
    monitoring-server.enable = true;
    monitoring-client.enable = true;
    mail = {
      enable = true;
      domain = "palebluebytes.space";
    };
    matrix.enable = true;
    paperless.enable = true;
    litellm.enable = true;
    openclaw.enable = true;
    blocky.enable = true;
    media = {
      enable = true;
    };
  };

  # OpenClaw models configuration — site-specific provider setup.
  # The gateway infrastructure (SOPS secrets, service config, port, etc.)
  # is handled by the openclaw profile; only the model routing is here.
  services.openclaw-gateway.config = {
    gateway.controlUi.allowedOrigins = [
      "https://openclaw.palebluebytes.space"
    ];
    models = {
      mode = "merge";
      providers = {
        litellm = {
          baseUrl = "http://127.0.0.1:4000";
          apiKey = "\${LITELLM_MASTER_KEY}";
          api = "openai-completions";
          models = [
            {
              id = "gemini-pro";
              name = "Gemini 2.5 Pro via DeepInfra";
              input = [ "text" "image" ];
              contextWindow = 1000000;
              maxTokens = 64000;
            }
            {
              id = "gemini-flash";
              name = "Gemini 2.5 Flash via DeepInfra";
              input = [ "text" "image" ];
              contextWindow = 1000000;
              maxTokens = 64000;
            }
            {
              id = "claude-4-sonnet";
              name = "Claude 4 Sonnet via DeepInfra";
              input = [ "text" "image" ];
              contextWindow = 200000;
              maxTokens = 64000;
            }
            {
              id = "deepseek-flash";
              name = "DeepSeek V4 Flash via DeepInfra";
              input = [ "text" ];
              contextWindow = 128000;
              maxTokens = 32000;
            }
            {
              id = "deepseek-pro";
              name = "DeepSeek V4 Pro via DeepInfra";
              input = [ "text" ];
              contextWindow = 128000;
              maxTokens = 32000;
            }
            {
              id = "minimax";
              name = "MiniMax M2.5 via DeepInfra";
              input = [ "text" ];
              contextWindow = 128000;
              maxTokens = 32000;
            }
            {
              id = "qwen3-coder";
              name = "Qwen3 Coder 480B via DeepInfra";
              input = [ "text" ];
              contextWindow = 128000;
              maxTokens = 32000;
            }
          ];
        };
      };
    };
    agents = {
      defaults = {
        model = {
          primary = "litellm/claude-4-sonnet";
        };
      };
    };
  };

  networking = {
    inherit (settings.nodes.kelpy) hostName domain;
  };

  services.restic.backups.daily.paths = [ "/persistent" ];

  nixpkgs = {
    hostPlatform = "x86_64-linux";
    config.permittedInsecurePackages = [
      "beekeeper-studio-5.5.7"
    ];
  };

  environment.systemPackages = with pkgs; [
    git
  ];

  system.stateVersion = "25.11";
}
