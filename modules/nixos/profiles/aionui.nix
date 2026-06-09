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
  # The local homeserver's name (see modules/nixos/profiles/matrix: server_name).
  matrixServer = "matrix.${config.networking.domain}";
in
{
  options.custom.profiles.aionui = {
    enable = lib.mkEnableOption "AionUi WebUI server (phone-accessible Claude Code frontend)";

    notifications = {
      enable = lib.mkEnableOption ''
        AionUi -> Matrix notifier. The only manual step is adding the bot's
        password to secrets/profiles/matrix.yaml as `aionui_matrix_bot_password`;
        the notifier then self-registers the bot (using the homeserver
        registration token) and creates the alerts room on first run.
      '';
      room = lib.mkOption {
        type = lib.types.str;
        default = "#aionui-alerts:${matrixServer}";
        description = "Room alias (auto-created) or id the notifier posts to.";
      };
      inviteUser = lib.mkOption {
        type = lib.types.str;
        default = "@inkpotmonkey:${matrixServer}";
        description = "Matrix account invited when the alerts room is created.";
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

    # Matrix notifier (opt-in). Secrets live in profiles/matrix.yaml: the bot
    # password (add manually) and the homeserver registration token (already
    # present, re-decrypted here for the notifier user to self-register the bot).
    sops.secrets = lib.mkIf cfg.notifications.enable {
      aionui_matrix_bot_password = {
        sopsFile = self.lib.getSecretPath "profiles/matrix.yaml";
        owner = config.services.aionui-notifier.user;
      };
      aionui_registration_token = {
        sopsFile = self.lib.getSecretPath "profiles/matrix.yaml";
        key = "registration_token";
        owner = config.services.aionui-notifier.user;
      };
    };
    services.aionui-notifier = lib.mkIf cfg.notifications.enable {
      enable = true;
      inherit (cfg.notifications) room inviteUser;
      passwordFile = config.sops.secrets.aionui_matrix_bot_password.path;
      registrationTokenFile = config.sops.secrets.aionui_registration_token.path;
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
