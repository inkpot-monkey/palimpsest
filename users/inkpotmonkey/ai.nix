{
  pkgs,
  config,
  inputs,
  ...
}:

{
  home.packages = with pkgs; [
    inputs.antigravity-nix.packages.${stdenv.hostPlatform.system}.default

    gemini-cli
    cursor-cli

    # n8n-mcp
    # pkgs.mcp-nixos

    kokoros # Default config (v1.0 model)
  ];

  programs.goose = {
    enable = true;
    provider = "ollama";
    model = "qwen2.5-coder:14b";
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

}
