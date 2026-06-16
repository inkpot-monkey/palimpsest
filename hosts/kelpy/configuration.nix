{
  inputs,
  pkgs,
  self,
  settings,
  ...
}:
{
  imports = [
    inputs.vpsFree.nixosModules.containerUnstable

    self.nixosProfiles.bundle
  ];

  custom.profiles = {
    base.enable = true;
    impermanence.enable = true;
    tailscale = {
      enable = true;
      tags = [ "tag:server" ];
    };
    ssh.enable = true;
    # Deliberately NOT passwordless sudo: kelpy is the public-facing VPS, so keep
    # the sudo password as defense-in-depth. `just deploy kelpy` supplies it via
    # --ask-sudo-password (prompted once, up front).
    proxy.enable = true;
    backup.enable = true;
    monitoring-server.enable = true;
    monitoring-client.enable = true;
    dmarc-exporter.enable = false;
    mail = {
      enable = true;
      domain = "palebluebytes.space";
      extraDomains = [ "palebluebytes.xyz" ];
    };
    matrix = {
      enable = true;
      whatsapp.enable = true;
      jmap-bridge.enable = true;
    };
    paperless.enable = true;
    litellm.enable = true;
    openclaw.enable = true;
    aionui.enable = true;
    blocky.enable = true;
    media = {
      enable = true;
    };
  };

  # OpenClaw models configuration — site-specific provider setup.
  # The gateway infrastructure (SOPS secrets, service config, port, etc.)
  # is handled by the openclaw profile; only the model routing is here.
  services.openclaw-gateway.config = {
    gateway.controlUi.allowedOrigins = [
      "https://openclaw.palebluebytes.space"
    ];
    models = {
      mode = "merge";
      providers = {
        litellm = {
          baseUrl = "http://127.0.0.1:4000";
          apiKey = "\${LITELLM_MASTER_KEY}";
          api = "openai-completions";
          # OpenClaw's per-provider idle timeout (time to first token). The local RK1 MoE
          # can spend many minutes prefilling a large prompt before it emits anything; the
          # default (~4 min) cuts it off as "LLM request timed out". Give it 2h. This is
          # distinct from the litellm request timeout and agents.defaults.timeoutSeconds.
          timeoutSeconds = 7200;
          models = [
            {
              id = "gemini-pro";
              name = "Gemini 2.5 Pro via DeepInfra";
              input = [
                "text"
                "image"
              ];
              contextWindow = 1000000;
              maxTokens = 64000;
            }
            {
              id = "gemini-flash";
              name = "Gemini 2.5 Flash via DeepInfra";
              input = [
                "text"
                "image"
              ];
              contextWindow = 1000000;
              maxTokens = 64000;
            }
            {
              id = "claude-4-sonnet";
              name = "Claude 4 Sonnet via DeepInfra";
              input = [
                "text"
                "image"
              ];
              contextWindow = 200000;
              maxTokens = 64000;
            }
            {
              id = "deepseek-flash";
              name = "DeepSeek V4 Flash via DeepInfra";
              input = [ "text" ];
              contextWindow = 128000;
              maxTokens = 32000;
            }
            {
              id = "deepseek-pro";
              name = "DeepSeek V4 Pro via DeepInfra";
              input = [ "text" ];
              contextWindow = 128000;
              maxTokens = 32000;
            }
            {
              id = "minimax";
              name = "MiniMax M2.5 via DeepInfra";
              input = [ "text" ];
              contextWindow = 128000;
              maxTokens = 32000;
            }
            {
              id = "qwen3-coder";
              name = "Qwen3 Coder 480B via DeepInfra";
              input = [ "text" ];
              contextWindow = 128000;
              maxTokens = 32000;
            }
            # Local model served by Turing Pi RK1 node rk1a via litellm (over tailscale).
            # CPU MoE decode is ~6-8 tok/s, so responses are slow but private and free.
            # Context matches the node's served ctxSize (rk1a 128K). rk1b was repurposed as
            # the Home Assistant voice node and no longer serves a coder model.
            {
              id = "qwen-general";
              name = "Qwen3.6 35B-A3B (local, rk1a)";
              input = [ "text" ];
              contextWindow = 131072;
              maxTokens = 16000;
            }
          ];
        };
      };
    };
    agents = {
      defaults = {
        model = {
          # Default agent model: the local general MoE on rk1a (qwen-general). rk1b's coder
          # model was removed (that board is now the Home Assistant voice node), so qwen-general
          # is the only local LLM. Routed via litellm, which falls back to cloud if rk1a is down.
          primary = "litellm/qwen-general";
        };
        # NO expert-subagent delegation on purpose. The rk1a board has a single llama.cpp
        # inference slot at ~6 tok/s, so fanning out to a second (and slower, thinking) model
        # concurrently just contends for / jams that one slot and trips the stall watchdog.
        # Keep OpenClaw a lean, serial, single-model consumer.
      };
    };

    # Trim the agent prompt for the slow local brain. The browser plugin (Playwright web
    # automation) is the single largest block of tool definitions in the prompt, and a
    # headless background/coding agent never browses — disabling it shrinks the prompt and
    # cuts prefill time. If still too large, the other paired-node plugins (canvas,
    # device-pair, phone-control, talk-voice, file-transfer) can be disabled the same way.
    plugins.entries.browser.enabled = false;
  };

  networking = {
    inherit (settings.nodes.kelpy) hostName domain;
  };

  services.restic.backups.daily.paths = [ "/persistent" ];

  # Persist the agent's home state across impermanence reboots: Claude Code
  # subscription credentials/config and the project checkouts AionUi works in.
  environment.persistence."/persistent".users.inkpotmonkey.directories = [
    ".claude"
    "code"
  ];

  nixpkgs = {
    hostPlatform = "x86_64-linux";
  };

  environment.systemPackages = with pkgs; [
    git
  ];

  system.stateVersion = "25.11";
}
