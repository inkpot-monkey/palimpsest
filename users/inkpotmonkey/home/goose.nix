{
  config,
  pkgs,
  inputs,
  lib,
  ...
}:
{
  options.custom.home.profiles.goose = {
    enable = lib.mkEnableOption "goose AI CLI tools";
  };

  config = lib.mkIf config.custom.home.profiles.goose.enable {
    home.packages =
      lib.optionals (pkgs.stdenv.hostPlatform.system == "x86_64-linux") [
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.goose-cli
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.backlog-md
      ]
      ++ [
        pkgs.nodejs
        pkgs.python3
      ]
      ++ lib.optionals (config.identity.profile == "gui") [
        pkgs.wtype
        pkgs.wl-clipboard
      ];

    sops.secrets."apikey@search.brave.com" = lib.mkIf (config.identity.profile == "gui") {
      sopsFile = ../secrets.yaml;
      format = "yaml";
    };
  };
}
