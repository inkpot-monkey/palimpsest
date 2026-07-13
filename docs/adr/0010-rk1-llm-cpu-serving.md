# RK1 LLM serving on CPU (MoE-only); NPU and multi-node RPC rejected

> **Superseded by [ADR-0027](0027-navidrome-friends-music-platform.md).** The local RK1
> LLM serving stack was retired — `services.llama-cpp`, `custom.rk1.llm`, and the
> `qwen-general` gateway model are gone; `rk1a` is freed and `rk1b` stays the voice node.
> This record is kept for *why* CPU-MoE-only serving was chosen while the stack existed;
> the claims below about `rk1a` currently serving an LLM no longer hold.

The RK1 nodes (Turing-Pi RK3588, 32 GB) serve local models with `services.llama-cpp` on **CPU**, fronted by the `litellm` gateway. Decode on this hardware is memory-bandwidth-bound (~19 GB/s), so speed scales as 1/active-params: a dense 27B runs at ~0.84 tok/s (unusable interactively) while a 3B-active MoE runs at ~6.2 tok/s. We therefore serve **only MoE models** (Qwen3 `*-A3B`) and tune around the bandwidth wall (A76 big-core pinning for decode ~6×, all-core prefill, n-gram speculative decoding, `--mlock` with raised `LimitMEMLOCK`).

Only `rk1a` now serves an LLM (`custom.rk1.llm`, the `qwen-general` MoE). `rk1b` was **repurposed as the voice node** — its coder MoE was removed to free RAM for Home Assistant + a Wyoming STT/TTS pipeline (`custom.rk1.homeAssistant`). A single RK1 board can't comfortably hold a 30B-class MoE *and* the voice stack, so the pair was split by role rather than running both models.

Two tempting alternatives were explicitly rejected. The **NPU** is a dead end for this fleet: RKLLM needs the Rockchip vendor BSP kernel (mainline 6.19 has no `/dev/rknpu`), is W8A8-only with tiny context and **no MoE support**, so our `*-A3B` models can't run on it at all. **Multi-node RPC** pools memory but not speed (still bandwidth-bound), so it only enables bigger models, not faster ones.

## Consequences

- Model selection is constrained to MoE architectures; don't propose dense models ≥27B for interactive use.
- The NPU could still pay off as a *separate* tiny always-on model (router/voice), but not as a replacement for the CPU MoE path; revisiting it means a kernel swap.
- NVMe (`custom.rk1.nvme`) enables bigger/more models, not faster inference.
