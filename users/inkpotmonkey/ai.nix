{
  pkgs,
  config,
  inputs,
  ...
}:

{
  imports = [
    inputs.self.homeManagerModules.goose
    inputs.self.homeManagerModules.kokoro-tts
  ];

  home.packages = with pkgs; [
    inputs.antigravity-nix.packages.${stdenv.hostPlatform.system}.default

    gemini-cli
    cursor-cli

    # n8n-mcp
    # pkgs.mcp-nixos

    alpaca
  ];

  # Define the secret so sops-nix extracts it
  sops.secrets."apikey@generativelanguage.googleapis.com" = { };

  programs.goose = {
    enable = true;
    provider = "google";
    model = "gemini-2.5-pro";
    env = {
      GOOGLE_API_KEY = config.sops.secrets."apikey@generativelanguage.googleapis.com";
    };
    # Declarative Profiles (Generates goose-flash, goose-ollama, etc.)
    profiles = {
      google = {
        provider = "google";
        model = "gemini-2.5-pro";
      };
      flash = {
        provider = "google";
        model = "gemini-3-flash";
      };
      next = {
        provider = "google";
        model = "gemini-3-pro-preview";
      };
      ollama = {
        provider = "ollama";
        model = "qwen2.5-coder:14b";
      };
    };
    extensions = [
      "developer"
      "computercontroller"
      "memory"
    ];
    mcpServers = {
      brave-search = {
        type = "stdio";
        command = "npx";
        args = [
          "-y"
          "@brave/brave-search-mcp-server"
        ];
        env = {
          BRAVE_API_KEY = config.sops.secrets."apikey@search.brave.com";
        };
      };

      # github = {
      #   type = "stdio";
      #   command = "${pkgs.github-mcp-server}/bin/github-mcp-server";
      #   args = [ "stdio" ];
      #   env = {
      #     GITHUB_PERSONAL_ACCESS_TOKEN = config.sops.secrets.github_token;
      #   };
      # };

      # weather-api = {
      #   type = "stdio";
      #   command = "${pkgs.emcee}/bin/emcee";
      #   args = [ "https://api.weather.gov/openapi.json" ];
      # };
    };
  };

  services.kokoro-tts = {
    enable = true;

    defaultVoices = {
      "en" = "bf_emma";
      "es" = "ef_dora";
    };
  };

}
