{
  pkgs,
  config,
  inputs,
  lib,
  self, ...
}:
{
  options.custom.home.profiles.ai = {
    enable = lib.mkEnableOption "AI tools and configurations";
  };

  imports = [
    inputs.self.homeManagerModules.kokoro-tts
  ];

  config = lib.mkIf config.custom.home.profiles.ai.enable {
    home.packages = with pkgs; [
      antigravity
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.cursor-agent
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.gemini-cli

      mcp-nixos
      playwright-driver.browsers
    ];

    home.sessionVariables = {
      PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
      PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
    };

    sops = {
      defaultSopsFile = self.lib.getSecretPath "users/inkpotmonkey.yaml";
      defaultSopsFormat = "yaml";
      # Define the secret for Home Manager
      secrets.litellm_key = {
        key = "litellm-key";
      };

      templates."eca-config" = {
        content = builtins.toJSON {
          providers = {
            litellm = {
              api = "openai-chat";
              url = "https://litellm.palebluebytes.space/v1";
              key = config.sops.placeholder.litellm_key;
              models = {
                "gemini/gemini-1.5-pro" = { };
                "anthropic/claude-3-5-sonnet-20240620" = { };
                "deepinfra/deepseek-ai/DeepSeek-V3" = { };
                "deepinfra/meta-llama/Llama-3-70b-instruct" = { };
              };
            };
          };
          defaultModel = "litellm/anthropic/claude-3-5-sonnet-20240620";
        };
        path = "${config.home.homeDirectory}/.config/eca/config.json";
      };
    };
  };
}
