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

  # Speculative decoding: pull a small draft model alongside the target.
  # The draft MUST share the target's tokenizer/vocab or llama.cpp rejects it.
  draftFlags = lib.optionals (cfg.draftModel != null) [
    "-hfd"
    cfg.draftModel
    # llama.cpp renamed --draft-max → --spec-draft-n-max (the old flag now hard-errors).
    "--spec-draft-n-max"
    "16"
  ];

  # Self-speculative decoding via the model's own Multi-Token-Prediction head.
  # No separate draft model — `model` must be an MTP-enabled GGUF (…-MTP-GGUF).
  mtpFlags = lib.optionals cfg.mtp [
    "--spec-type"
    "draft-mtp"
  ];

  # N-gram speculative decoding: drafts tokens from context n-grams (no model, no RAM) and
  # verifies a batch in one weight-read, so it beats the bandwidth wall when output reuses
  # context. Benchmarked on the coder MoE: +27% on code-echo/edit, +3.5% on novel gen, lossless
  # (verify guarantees identical output). map-k beat ngram-simple (0.93 vs 0.75 acceptance).
  ngramFlags = lib.optionals cfg.ngram [
    "--spec-type"
    "ngram-map-k"
    "--spec-draft-n-max"
    "16"
  ];

  # Flash-attention + quantized KV go together (q8_0 KV requires -fa on). On the RK3588 CPU
  # backend the extra dequant work can cost decode tok/s, so this is a measured per-node knob.
  faFlags =
    if cfg.flashAttention then
      [
        "-fa"
        "on"
        "--cache-type-k"
        "q8_0"
        "--cache-type-v"
        "q8_0"
      ]
    else
      [
        "-fa"
        "off"
      ];

  # CPU placement (RK3588: cores 0-3 = A55 little, 4-7 = A76 big). Decode is bandwidth-bound and
  # the A55s only bottleneck it, so pin decode strictly to the A76 cores. Prefill (prompt
  # processing) is compute-bound and parallelizes, so let it use ALL cores — the A55s add ~11%
  # there with no decode regression (measured). Uses llama.cpp's per-phase strict affinity
  # instead of a blanket systemd CPUAffinity so the two phases can target different cores.
  cpuFlags = lib.optionals cfg.pinBigCores [
    "-Cr"
    "4-7"
    "--cpu-strict"
    "1"
    "-Crb"
    "0-7"
    "--cpu-strict-batch"
    "1"
  ];
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
      host = "0.0.0.0";
      inherit (cfg) port;
      extraFlags = [
        "-hf"
        cfg.model
        "-t"
        (toString cfg.threads)
        "-tb"
        (toString cfg.threadsBatch)
        "-c"
        (toString cfg.ctxSize)
        "-np"
        "1"
      ]
      ++ faFlags
      ++ cpuFlags
      ++ lib.optional cfg.mlock "--mlock"
      ++ draftFlags
      ++ mtpFlags
      ++ ngramFlags;
    };

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

    # Expose the port only on the tailnet, not the public LAN.
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ cfg.port ];
  };
}
