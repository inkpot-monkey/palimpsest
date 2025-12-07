{
  pkgs,
  config,
  inputs,
  ...
}:
let
  mcpConfig = {
    mcpServers = {
      nixos = {
        command = "${pkgs.mcp-nixos}/bin/mcp-nixos";
      };
      github = {
        command = "${pkgs.github-mcp-server}/bin/github-mcp-server";
        args = [ "stdio" ];
        env = {
          GITHUB_PERSONAL_ACCESS_TOKEN = config.sops.placeholder.github_token;
        };
      };
      n8n-mcp = {
        command = "${pkgs.n8n-mcp}/bin/n8n-mcp";
        env = {
          MCP_MODE = "stdio";
          LOG_LEVEL = "error";
          DISABLE_CONSOLE_OUTPUT = true;
          N8N_API_URL = "YOUR_API_URL";
          N8N_API_KEY = "YOUR_API_KEY";
        };
      };
      playwright = {
        command = "${pkgs.playwright-mcp}/bin/playwright-mcp";
      };
      weather-api = {
        command = "${pkgs.emcee}/bin/emcee";
        args = [
          "https=//api.weather.gov/openapi.json"
        ];
      };
    };
  };
in

{
  home.packages = with pkgs; [
    cursor-cli
    gemini-cli
    claude-code
    n8n-mcp
    inputs.antigravity-nix.packages.x86_64-linux.default
    emcee
  ];

  sops.templates."mcp_config.json" = {
    content = builtins.toJSON mcpConfig;
    path = "${config.xdg.configHome}/mcp/mcp_config.json";
  };
}
