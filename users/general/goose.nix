{
  config,
  pkgs,
  inputs,
  osConfig,
  ...
}:

{
  home.packages = [
    inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.goose-cli
    inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.backlog-md
    inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.coding-agent-search
    # pkgs.mcp-nixos
    # pkgs.mcp-grafana
    pkgs.nodejs
    pkgs.python3
    # Required for computercontroller Linux automation
    pkgs.wtype
    pkgs.wl-clipboard
  ];

  sops.secrets = {
    grafana_api_key = { };
    brave_search_api_key = { };
  };

  home.sessionVariables = {
    GRAFANA_URL = "http://localhost:${toString osConfig.services.grafana.settings.server.http_port}";
  };
}
