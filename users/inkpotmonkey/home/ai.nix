{
  pkgs,
  config,
  inputs,
  lib,
  ...
}:

{
  imports = [
    inputs.self.homeManagerModules.kokoro-tts
  ];

  config = lib.mkIf (config.identity.profile == "gui") {
    home.packages = with pkgs; [
      antigravity
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.cursor-agent
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.gemini-cli

      mcp-nixos

      # alpaca
    ];

    # Define the secret so sops-nix extracts it
    # sops.secrets."apikey@generativelanguage.googleapis.com" = { };

    # programs.goose = {
    #   enable = true;
    #   provider = "google";
    #   model = "gemini-2.5-pro";
    #   env = {
    #     GOOGLE_API_KEY = config.sops.secrets."apikey@generativelanguage.googleapis.com";
    #   };
    #   # Declarative Profiles (Generates goose-flash, goose-ollama, etc.)
    #   profiles = {
    #     google = {
    #       provider = "google";
    #       model = "gemini-2.5-pro";
    #     };
    #     flash = {
    #       provider = "google";
    #       model = "gemini-3-flash";
    #     };
    #     next = {
    #       provider = "google";
    #       model = "gemini-3-pro-preview";
    #     };
    #     ollama = {
    #       provider = "ollama";
    #       model = "qwen2.5-coder:14b";
    #     };
    #   };
    #   extensions = [
    #     "developer"
    #     "computercontroller"
    #     "memory"
    #   ];
    #   mcpServers = {
    #     brave-search = {
    #       type = "stdio";
    #       command = "npx";
    #       args = [
    #         "-y"
    #         "@brave/brave-search-mcp-server"
    #       ];
    #       env = {
    #         BRAVE_API_KEY = config.sops.secrets."apikey@search.brave.com";
    #       };
    #     };
    #     };
    #   };
    # };

    # services.kokoro-tts = {
    #   enable = true;

    #   defaultVoices = {
    #     "en" = "bf_emma";
    #     "es" = "ef_dora";
    #   };
    # };
  };
}
