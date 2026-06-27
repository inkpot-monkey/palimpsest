# Local llama.cpp LLM server, RK3588-tuned. This lives with the rk1 host config rather than in
# the shared modules/nixos/profiles/ because only the Turing Pi RK1 nodes serve LLMs — the
# tuning (A76 core pinning, flash-attn off, MoE-oriented) is specific to this hardware.
# Option namespace matches the sibling ./nvme.nix module: custom.rk1.*
{
  config,
  lib,
  ...
}:

let
  cfg = config.custom.rk1.llm;
in
{
  options.custom.rk1.llm = {
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

    mtp = lib.mkEnableOption ''
      Multi-Token-Prediction self-speculative decoding (`--spec-type draft-mtp`).
      `model` must be an MTP-enabled GGUF (e.g. unsloth/Qwen3.6-27B-MTP-GGUF); the
      draft tokens come from the model's own MTP head, so no separate draftModel is
      needed (and the two are mutually exclusive)
    '';

    ngram = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        N-gram speculative decoding (`--spec-type ngram-map-k`). Drafts from context n-grams —
        no draft model, no extra RAM, lossless. Benchmarked: +27% on code-echo/edit, +3.5% on
        novel gen, no downside. Default on. Mutually exclusive with `mtp`/`draftModel`.
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
        Generation (decode) threads. On RK3588, 4 (the A76 cores) outperforms 8 — the slower
        A55 cores bottleneck the bandwidth-bound decode loop.
      '';
    };

    threadsBatch = lib.mkOption {
      type = lib.types.int;
      default = 8;
      description = ''
        Prompt-processing (prefill) threads. Unlike decode, prefill is compute-bound and
        parallelizes, so all 8 cores help (~11% faster first-token, no decode regression).
        With pinBigCores, prefill is placed across cores 0-7 while decode stays on the A76s.
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

    flashAttention = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable flash attention (`-fa on`) with quantized q8_0 KV cache. Benchmarked on the
        RK3588 CPU backend (Qwen3-Coder-30B-A3B): `-fa off` + f16 KV is ~3% faster (6.22 vs
        6.04 tok/s) and higher KV quality, so the default is off. RAM cost of f16 KV is small
        at 4096 ctx. Flip to true only if a model/quant measures faster with it.
      '';
    };

    pinBigCores = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        RK3588 core placement via llama.cpp strict per-phase affinity: decode threads pinned to
        the A76 big cores (4-7) — ~6× vs landing on A55s (measured 1.0 vs 6.2 tok/s) — while
        prefill threads span all cores (0-7) for faster first-token. RK3588-specific.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.llama-cpp = {
      enable = true;
      # Bind on all interfaces; the firewall below scopes access to tailscale only.
      settings = {
        host = "0.0.0.0";
        inherit (cfg) port;
        hf-repo = cfg.model;
        t = cfg.threads;
        threads-batch = cfg.threadsBatch;
        ctx-size = cfg.ctxSize;
        parallel = 1;
        inherit (cfg) mlock; # true → --mlock flag; false → omitted (explicitBool=false)
        flash-attn = if cfg.flashAttention then "on" else "off";
      }
      // lib.optionalAttrs cfg.flashAttention {
        cache-type-k = "q8_0";
        cache-type-v = "q8_0";
      }
      // lib.optionalAttrs cfg.pinBigCores {
        cpu-range = "4-7"; # -Cr: A76 big cores for decode
        cpu-strict = 1;
        cpu-range-batch = "0-7"; # -Crb: all cores for prefill
        cpu-strict-batch = 1;
      }
      // lib.optionalAttrs (cfg.draftModel != null) {
        hf-repo-draft = cfg.draftModel;
        spec-draft-n-max = 16;
      }
      // lib.optionalAttrs cfg.mtp {
        spec-type = "draft-mtp";
        spec-draft-n-max = 16;
      }
      // lib.optionalAttrs cfg.ngram {
        spec-type = "ngram-map-k";
        spec-draft-n-max = 16;
      };
    };

    # `--mlock` needs a high memlock rlimit or it silently fails (systemd default is 8 MB) and the
    # weights fall back to reclaimable page cache. Lock them so a large-context prefill can't evict
    # the model and force slow re-reads from eMMC. The locked footprint (model + KV) was measured
    # to fit per node (rk1a 128K ≈ 20G, rk1b 64K ≈ 22G of 32G).
    systemd.services.llama-cpp.serviceConfig.LimitMEMLOCK = lib.mkIf cfg.mlock "infinity";

    assertions = [
      {
        # At most one speculative-decoding method (they all drive --spec-type / -hfd).
        assertion =
          lib.count (x: x) [
            cfg.ngram
            cfg.mtp
            (cfg.draftModel != null)
          ] <= 1;
        message = "custom.rk1.llm: enable at most one of `ngram`, `mtp`, `draftModel`.";
      }
    ];

    # Persist the HuggingFace model cache across impermanence reboots.
    # /var/cache/llama-cpp holds the downloaded GGUF blobs (up to ~20G); without this
    # the service would need to re-download the full model on every boot.
    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [ "/var/cache/llama-cpp" ];
    };

    # Expose the port only on the tailnet, not the public LAN.
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ cfg.port ];
  };
}
