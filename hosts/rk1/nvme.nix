# Optional M.2 NVMe storage for the Turing Pi RK1 nodes.
#
# The 29 GB eMMC is too small for the big model caches these nodes can host: full-quant
# GGUF weights for the LLM node (a Q4/Q5 of the 27B/35B is 17-32 GB), or the torch +
# Whisper/pyannote model downloads for the voice node's WhisperX batch transcription.
# This module mounts an NVMe drive at /var/cache so those model caches (and systemd's
# DynamicUser private cache dirs under /var/cache/private/*) land on the big disk while
# the OS stays on eMMC. It is consumer-agnostic: whichever cache-heavy service the node
# runs adds its own RequiresMountsFor=/var/cache (this module wires llama-cpp's when present).
#
# Imported (inert) by hosts/rk1/common.nix. Enable per node once the drive is fitted:
#
#   custom.rk1.nvme.enable = true;
#   custom.rk1.nvme.device = "/dev/disk/by-label/rk1cache";  # default
#
# ── One-time disk prep on the node (destroys data on the NVMe) ──────────────────
#   sudo wipefs -a /dev/nvme0n1
#   sudo parted -s /dev/nvme0n1 mklabel gpt mkpart primary ext4 0% 100%
#   sudo mkfs.ext4 -L rk1cache /dev/nvme0n1p1
# Then enable the option above and redeploy. On first boot llama.cpp re-downloads
# the model onto the NVMe; bump the quant back up in hosts/default.nix.
#
# NOTE: /nix can also be moved to NVMe for headroom, but that needs a live store
# migration (rsync /nix to the new fs, add a fileSystems."/nix" entry, reboot) and
# is intentionally out of scope here — the model cache is what overflows the eMMC.
{ config, lib, ... }:
let
  cfg = config.custom.rk1.nvme;
in
{
  options.custom.rk1.nvme = {
    enable = lib.mkEnableOption "host the llama.cpp model cache on an M.2 NVMe drive";

    device = lib.mkOption {
      type = lib.types.str;
      default = "/dev/disk/by-label/rk1cache";
      description = "Block device (or /dev/disk/by-* path) of the formatted NVMe model cache.";
    };

    fsType = lib.mkOption {
      type = lib.types.str;
      default = "ext4";
      description = "Filesystem on the NVMe model-cache partition.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Park the whole /var/cache on the NVMe. systemd's CacheDirectory=llama-cpp (and the
    # DynamicUser indirection at /var/cache/private/llama-cpp) then live on the big disk,
    # with systemd still managing ownership/permissions.
    fileSystems."/var/cache" = {
      inherit (cfg) device fsType;
      # nofail: a missing/un-fitted drive must not strand the boot. The service dependency
      # below keeps llama.cpp from starting (and re-filling eMMC) when the cache disk is absent.
      options = [
        "nofail"
        "x-systemd.device-timeout=15s"
      ];
    };

    # Don't start the LLM server until its model disk is actually mounted (only on the LLM
    # node — the voice node has no llama-cpp service, and a bare unitConfig would otherwise
    # define a phantom unit). Cache-heavy services on other nodes (e.g. WhisperX) add their
    # own RequiresMountsFor=/var/cache in their module.
    systemd.services.llama-cpp.unitConfig.RequiresMountsFor =
      lib.mkIf config.services.llama-cpp.enable
        [ "/var/cache" ];
  };
}
