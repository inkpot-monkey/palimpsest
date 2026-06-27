{
  config,
  inputs,
  lib,
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
    # Temporarily disabled: the restic repo (zh2046.rsync.net) is unreachable and
    # holds a stale exclusive lock from stargazer, failing every activation.
    # Re-enable once the lock is cleared and the host is reachable.
    backup.enable = false;
    monitoring-server.enable = false; # moved to rk1b (ADR-0028)
    monitoring-client.enable = true;
    monitoring-dmarc.enable = false;
    # On-host white-box layer for ADR-0026: alerts to #infra-alerts (via the
    # hookshot loopback webhook) when a long-running daemon stops being active —
    # complements the off-host Gatus reachability probe on rk1b. The unit list is
    # CURATED (these names are kelpy-specific); add/remove as services change.
    # affine is intentionally omitted (it currently has no unit on kelpy).
    monitoring-unit-state = {
      enable = true;
      units = [
        "caddy.service" # the edge — everything web-facing depends on it
        "blocky.service" # fleet DNS
        "stalwart.service" # mail
        "tuwunel.service" # matrix homeserver
        "matrix-hookshot.service" # the alert delivery path itself
        "litellm.service"
        "openclaw-gateway.service"
        "jellyfin.service"
        "podman-qbittorrent-app.service" # torrent
        "vector.service" # monitoring-client still runs here; server moved to rk1b
        "paperless-scheduler.service"
        "paperless-task-queue.service"
        "paperless-consumer.service"
      ];
    };
    mail = {
      enable = true;
      inherit (settings.mail) domain extraDomains;
    };
    matrix = {
      enable = true;
      whatsapp.enable = true;
      jmap-bridge.enable = true;
      hookshot.enable = true;
      infraAlerts = {
        enable = true;
        # Pinned from the matrix-infra-alerts-room oneshot's first run (a static
        # hookshot connection needs the server-assigned roomId at build time).
        roomId = "!oHttFPAVTE9qwcYCjp:matrix.palebluebytes.space";
      };
    };
    paperless.enable = true;
    litellm.enable = true;
    openclaw.enable = true;
    # The Claude relay (ADR-0025) is the Matrix interface to persistent `claude`
    # sessions — it replaced AionUi (now removed). Reuses inkpotmonkey's ~/.claude.
    claude-relay.enable = true;
    blocky.enable = true;
    media = {
      enable = true;
    };
  };

  # kelpy runs the Claude relay's code-executing `claude` sessions (claude-relay
  # above) — mark it exposed so the contract refuses any secret-bearing user-feature
  # grant (ADR-0015).
  custom.host.exposed = true;
  # NOTE: signing is intentionally NOT granted here. It is now a home-sops feature
  # (ADR-0018, slice 13) decryptable only by the user's own key, which a headless
  # agent host lacks — and the agent should not sign commits as inkpotmonkey anyway.

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

  # Gate the WHOLE `daily` entry on the backup profile: writing `.daily.paths`
  # alone would still instantiate `restic.backups.daily` (empty → fails the
  # repository/passwordFile assertions) when the profile, which supplies those,
  # is disabled. mkIf on the attrset removes the entry entirely.
  services.restic.backups.daily = lib.mkIf config.custom.profiles.backup.enable {
    paths = [ "/persistent" ];
  };

  # Persist the agent's home state across impermanence reboots: Claude Code
  # subscription credentials/config and the project checkouts the relay's sessions
  # work in.
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
