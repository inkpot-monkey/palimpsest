{
  config,
  pkgs,
  inputs,
  lib,
  ...
}:

{
  config = lib.mkMerge [
    {
      home.packages =
        lib.optionals (pkgs.stdenv.hostPlatform.system == "x86_64-linux") [
          inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.goose-cli
          inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.backlog-md
          # inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.coding-agent-search
        ]
        ++ [
          # pkgs.mcp-nixos
          # pkgs.mcp-grafana
          pkgs.nodejs
          pkgs.python3
        ];
    }
    (lib.mkIf (config.identity.profile == "gui") {
      home.packages = [
        pkgs.wtype
        pkgs.wl-clipboard
      ];

      sops.secrets."apikey@search.brave.com" = {
        sopsFile = ../secrets.yaml;
        format = "yaml";
      };
    })
  ];

  # environment.sessionVariables = {
  #   GRAFANA_URL = "http://localhost:${toString config.services.grafana.settings.server.http_port}";
  # };
}
