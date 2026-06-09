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

    notifications = {
      enable = lib.mkEnableOption ''
        AionUi -> Matrix notifier. Opt-in: requires the one-time bootstrap first
        (register a Matrix bot, create the room, add its access token to
        secrets/profiles/matrix.yaml as `aionui_matrix_token`, set `roomId`).
      '';
      roomId = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "!abcdef:matrix.palebluebytes.space";
        description = "Matrix room ID the notifier posts agent events to.";
      };
    };
  };

  imports = [
    self.nixosModules.aionui
    self.nixosModules.aionui-notifier
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

    # Matrix notifier (opt-in; see notifications option + bootstrap below).
    sops.secrets.aionui_matrix_token = lib.mkIf cfg.notifications.enable {
      sopsFile = self.lib.getSecretPath "profiles/matrix.yaml";
      owner = config.services.aionui-notifier.user;
    };
    services.aionui-notifier = lib.mkIf cfg.notifications.enable {
      enable = true;
      inherit (cfg.notifications) roomId;
      tokenFile = config.sops.secrets.aionui_matrix_token.path;
      matrixUrl = "http://127.0.0.1:${toString settings.services.public.matrix.port}";
      aionuiUrl = "http://127.0.0.1:${toString settings.services.private.aionui.port}";
    };

    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        "/var/lib/aionui"
      ]
      ++ lib.optional cfg.notifications.enable "/var/lib/aionui-notifier";
    };
  };
}
