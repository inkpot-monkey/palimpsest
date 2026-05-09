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
  cfg = config.custom.profiles.openclaw;
in
{
  options.custom.profiles.openclaw = {
    enable = lib.mkEnableOption "OpenClaw gateway configuration";
  };

  imports = [
    inputs.openclaw-nix.nixosModules.openclaw-gateway
  ];

  config = lib.mkIf cfg.enable {

    sops.secrets = {
      openclaw_gateway_token = {
        sopsFile = self.lib.getSecretPath "profiles/ai.yaml";
        key = "openclaw";
      };
      litellm_key = {
        sopsFile = self.lib.getSecretPath "profiles/ai.yaml";
        key = "litellm-key";
      };
    };

    sops.templates."openclaw-env" = {
      content = ''
        OPENCLAW_GATEWAY_TOKEN=${config.sops.placeholder.openclaw_gateway_token}
        LITELLM_MASTER_KEY=${config.sops.placeholder.litellm_key}
      '';
    };

    services.openclaw-gateway = {
      enable = true;
      package = inputs.openclaw-nix.packages.${pkgs.stdenv.hostPlatform.system}.openclaw-gateway;
      inherit (settings.services.private.openclaw) port;

      environmentFiles = [ config.sops.templates."openclaw-env".path ];

      config = {
        gateway = {
          mode = "local";
          bind = "loopback";
          controlUi = {
            enabled = true;
            allowInsecureAuth = true;
            dangerouslyDisableDeviceAuth = true;
          };
          auth = {
            mode = "token";
          };
        };
        agents = {
          defaults = {
            model = {
              primary = "litellm/deepseek-flash";
              fallbacks = [ "litellm/deepseek-pro" ];
            };
          };
        };
      };
    };

    systemd.services.openclaw-gateway = {
      after = [ "sops-install-secrets.service" ];
      wants = [ "sops-install-secrets.service" ];
    };

    environment.systemPackages = with pkgs; [
      inputs.openclaw-nix.packages.${pkgs.stdenv.hostPlatform.system}.openclaw-gateway

      # Node.js / npx — required for MCP servers
      nodejs

      # Chromium-based browser for OpenClaw's browser tool (managed browser profile).
      chromium
    ];

    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        "/var/lib/openclaw"
      ];
    };
  };
}
