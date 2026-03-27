{
  pkgs,
  ...
}:
{
  home.packages = [
    # inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.goose-cli
    # inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.backlog-md
    # inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.coding-agent-search
    pkgs.nodejs
    pkgs.python3
    # Required for computercontroller Linux automation
    pkgs.wtype
    pkgs.wl-clipboard
  ];

  sops.secrets = {
    "apikey@generativelanguage.googleapis.com" = { };
    "apikey@api.anthropic.com" = { };
    "apikey@api.deepinfra.com" = { };
  };

  # home.sessionVariables = {
  #   GRAFANA_URL = "http://localhost:${toString osConfig.services.grafana.settings.server.http_port}";
  # };
}
