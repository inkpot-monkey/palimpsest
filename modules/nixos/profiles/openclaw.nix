{
  config,
  lib,
  inputs,
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

    # Pin the openclaw uid/gid. Otherwise auto-allocated, they get reshuffled by a
    # reboot that re-derives the system-user map, which orphans /var/lib/openclaw
    # (its sqlite ends up owned by another service's id) and crash-loops the gateway.
    users.users.openclaw.uid = 989;
    users.groups.openclaw.gid = 987;

    services.openclaw-gateway = {
      enable = true;
      package = inputs.openclaw-nix.packages.${pkgs.stdenv.hostPlatform.system}.openclaw-gateway;
      # Loopback port for the gateway. Hardcoded because the `openclaw` entry in
      # settings.services was dropped when the service was disabled (ADR-0027); re-add that
      # entry (with a Caddy vhost + monitor) if openclaw returns as a served service.
      port = 8001;

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
          # Default agent (`main`) runs on a cloud model via LiteLLM. The local rk1 MoE that
          # once backed a slow background agent was retired with the local-LLM stack (ADR-0027),
          # so there is no local brain to route to; the generous run-timeout ceiling is a cap,
          # not a delay, and is harmless for the fast cloud agent.
          defaults = {
            model = {
              primary = "litellm/deepseek-flash";
              fallbacks = [ "litellm/deepseek-pro" ];
            };
            timeoutSeconds = 7200;
          };
        };
      };
    };

    systemd.services.openclaw-gateway = {
      after = [ "sops-install-secrets.service" ];
      wants = [ "sops-install-secrets.service" ];
      # The upstream module writes /etc/openclaw/openclaw.json as a plain activation file, which
      # does NOT restart the service when it changes — so a `deploy` updates the config on disk
      # but leaves the gateway running the previous one (e.g. a newly added agent stays unknown
      # until a manual restart). Tie a restart to the config content so deploys actually apply it.
      restartTriggers = [ (builtins.toJSON config.services.openclaw-gateway.config) ];
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
