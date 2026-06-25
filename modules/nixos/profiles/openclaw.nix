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

    # Pin the openclaw uid/gid. Otherwise auto-allocated, they get reshuffled by a
    # reboot that re-derives the system-user map, which orphans /var/lib/openclaw
    # (its sqlite ends up owned by another service's id) and crash-loops the gateway.
    users.users.openclaw.uid = 989;
    users.groups.openclaw.gid = 987;

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
          # Default agent (`main`) stays on the fast cloud model for interactive use. The
          # generous global run-timeout ceiling lets a slow local-brain background run
          # (multi-minute prefill) finish instead of being cut — it's a cap, not a delay, so
          # the fast cloud agent is unaffected.
          #
          # The rk1-only background brain is NOT declared here: this OpenClaw version registers
          # addressable agents from STATE (`/var/lib/openclaw`), not from config (`agents.list`
          # validates but does nothing). Provision it once against the running gateway:
          #   openclaw agents add rk1-bg --model litellm/qwen-general \
          #     --workspace /var/lib/openclaw/workspace-rk1-bg --non-interactive
          # then drive it with `openclaw agent --agent rk1-bg --message ... --timeout 7200`.
          # /var/lib/openclaw is persisted (impermanence), so the agent survives reboots.
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
