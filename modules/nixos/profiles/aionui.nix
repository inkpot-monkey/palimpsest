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
        AionUi -> Matrix notifier (webhook mode). Posts agent events through a
        matrix-hookshot generic webhook — hookshot owns the Matrix side. Manual
        step: in Matrix, add the hookshot bot to a room, create a generic webhook
        there (`webhook`), and store its URL in secrets/profiles/matrix.yaml as
        `aionui_hookshot_webhook_url` (leave it empty until you have it — the
        notifier idles until the URL is present).
      '';
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
        pkgs.gh # so the agent can `gh pr create`
        pkgs.nodejs
      ];

      # Authenticate `gh` (and thus `gh pr create`) headlessly with the same token
      # git uses for HTTPS push. The raw github_token secret isn't KEY=VALUE, so
      # it's rendered to an env file via the sops template defined below.
      environmentFile = config.sops.templates."aionui-gh-env".path;
    };

    # GH_TOKEN for the agent's `gh`, rendered from the system github_token secret
    # (declared in modules/nixos/profiles/nixConfig.nix from profiles/github.yaml).
    sops.templates."aionui-gh-env" = {
      content = "GH_TOKEN=${config.sops.placeholder.github_token}\n";
      owner = config.services.aionui.user;
      inherit (config.services.aionui) group;
    };

    # Matrix notifier (opt-in, webhook mode). The only secret is the hookshot
    # generic-webhook URL in profiles/matrix.yaml (add manually; may start empty
    # — the notifier idles until it's populated, then delivers without a restart).
    sops.secrets.aionui_hookshot_webhook_url = lib.mkIf cfg.notifications.enable {
      sopsFile = self.lib.getSecretPath "profiles/matrix.yaml";
      owner = config.services.aionui-notifier.user;
    };
    services.aionui-notifier = lib.mkIf cfg.notifications.enable {
      enable = true;
      webhookUrlFile = config.sops.secrets.aionui_hookshot_webhook_url.path;
      aionuiUrl = "http://127.0.0.1:${toString settings.services.private.aionui.port}";
    };

    # Persisted dirs must be created owned by their service users (a bare string
    # would make them root-owned, which the non-root services can't write to).
    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        {
          directory = "/var/lib/aionui";
          inherit (config.services.aionui) user group;
          mode = "0750";
        }
      ]
      ++ lib.optional cfg.notifications.enable {
        directory = "/var/lib/aionui-notifier";
        inherit (config.services.aionui-notifier) user group;
        mode = "0750";
      };
    };
  };
}
