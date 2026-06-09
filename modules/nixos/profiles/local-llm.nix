{
  config,
  lib,
  ...
}:

let
  cfg = config.custom.profiles.localLlm;

  # Speculative decoding: pull a small draft model alongside the target.
  # The draft MUST share the target's tokenizer/vocab or llama.cpp rejects it.
  draftFlags = lib.optionals (cfg.draftModel != null) [
    "-hfd"
    cfg.draftModel
    "--draft-max"
    "16"
  ];
in
{
  options.custom.profiles.localLlm = {
    enable = lib.mkEnableOption "local llama.cpp LLM server (RK3588-tuned)";

    model = lib.mkOption {
      type = lib.types.str;
      example = "unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_XL";
      description = "HuggingFace GGUF spec passed to `llama-server -hf` (the per-node knob).";
    };

    draftModel = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "unsloth/Qwen3.6-1.7B-GGUF:Q4_K_M";
      description = ''
        Optional HuggingFace GGUF for speculative decoding (`-hfd`). Must share the
        target model's tokenizer/vocab, otherwise the draft is silently disabled.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Listen port for the llama.cpp OpenAI-compatible server.";
    };

    threads = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = ''
        Generation threads. On RK3588, 4 (the A76 cores) outperforms 8 — the slower
        A55 cores bottleneck the pipeline.
      '';
    };

    ctxSize = lib.mkOption {
      type = lib.types.int;
      default = 4096;
      description = "Context window (-c). Larger uses more RAM and slows generation.";
    };

    mlock = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Pin model weights in RAM (--mlock). Disable when RAM is contended.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.llama-cpp = {
      enable = true;
      # Bind on all interfaces; the firewall below scopes access to tailscale only.
      host = "0.0.0.0";
      inherit (cfg) port;
      extraFlags = [
        "-hf"
        cfg.model
        "-t"
        (toString cfg.threads)
        "-c"
        (toString cfg.ctxSize)
        "-np"
        "1"
        # Flash attention + quantized KV cache: less RAM, a bit faster on CPU.
        "-fa"
        "on"
        "--cache-type-k"
        "q8_0"
        "--cache-type-v"
        "q8_0"
      ]
      ++ lib.optional cfg.mlock "--mlock"
      ++ draftFlags;
    };

    # Expose the port only on the tailnet, not the public LAN.
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ cfg.port ];
  };
}
