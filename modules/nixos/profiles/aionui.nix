{
  config,
  lib,
  inputs,
  settings,
  pkgs,
  self,
  ...
}:

let
  cfg = config.custom.profiles.aionui;
  claude-code = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.claude-code;
in
{
  options.custom.profiles.aionui = {
    enable = lib.mkEnableOption "AionUi WebUI server (phone-accessible Claude Code frontend)";
  };

  imports = [
    self.nixosModules.aionui
  ];

  config = lib.mkIf cfg.enable {
    services.aionui = {
      enable = true;
      package = pkgs.aionui;
      inherit (settings.services.private.aionui) port;

      # Run as the interactive user so AionUi reuses its `claude login`
      # credentials (~/.claude) and can work inside ~/code project checkouts.
      user = "inkpotmonkey";
      group = "users"; # inkpotmonkey's primary group (no per-user group exists)
      createUser = false;

      # Make the agent CLIs + their tooling discoverable to the backend.
      agentPackages = [
        claude-code
        pkgs.git
        pkgs.nodejs
      ];
    };

    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        "/var/lib/aionui"
      ];
    };
  };
}
