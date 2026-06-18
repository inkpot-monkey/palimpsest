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
# ── relocateNixStore: also put /nix on the NVMe ─────────────────────────────────
# Set `custom.rk1.nvme.relocateNixStore = true;` to mount /nix from the drive
# (label `nixstore`). This is what unblocks piBuilder (build-offload): the 29 GB
# eMMC can't assemble a ~6.8 GB Pi sd-image, but a 400 GB NVMe /nix can. /nix is
# `neededForBoot` so it mounts in stage-1 (the initrd already carries the `nvme`
# driver); /boot stays on eMMC, so the kernel+initrd that mount /nix are unaffected.
#
# ── One-time disk prep on the node (DESTROYS data on the NVMe) ───────────────────
# rk1 images ship only util-linux (no parted/sgdisk), so partition with sfdisk:
#   printf 'label: gpt\nsize=400G, name=nixstore, type=L\nname=rk1cache, type=L\n' \
#     | sudo sfdisk /dev/nvme0n1
#   sudo mkfs.ext4 -F -L nixstore /dev/nvme0n1p1
#   sudo mkfs.ext4 -F -L rk1cache /dev/nvme0n1p2
# Then migrate the store before rebooting onto the new layout:
#   1. enable the options, `nixos-rebuild boot` (builds the new closure into eMMC /nix
#      and writes the initrd that will mount /nix from `nixstore` — does NOT activate),
#   2. mount nixstore, `rsync -aHAX --delete /nix/ /mnt/nixstore/` (-H preserves the
#      store's hardlinks), confirm the copy, then reboot. Model caches under /var/cache
#      re-download on first use.
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

    relocateNixStore = lib.mkEnableOption ''
      mounting /nix from the NVMe (label `nixstore`) so the store has room for build
      offload (piBuilder). /nix is neededForBoot — see the header for the migration recipe
    '';

    nixStoreDevice = lib.mkOption {
      type = lib.types.str;
      default = "/dev/disk/by-label/nixstore";
      description = "Block device of the NVMe /nix partition (used when relocateNixStore = true).";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        # Park the whole /var/cache on the NVMe. systemd's CacheDirectory=llama-cpp (and the
        # DynamicUser indirection at /var/cache/private/llama-cpp) then live on the big disk,
        # with systemd still managing ownership/permissions.
        fileSystems."/var/cache" = {
          inherit (cfg) device fsType;
          # nofail: a missing/un-fitted drive must not strand the boot. The service dependency
          # below keeps llama.cpp from starting (re-filling eMMC) when the cache disk is absent.
          # noatime: it's a pure cache — skip access-time writes (less SSD wear).
          options = [
            "nofail"
            "noatime"
            "x-systemd.device-timeout=15s"
          ];
        };

        # Periodic TRIM keeps the SSD healthy (preferred over the continuous `discard` option).
        services.fstrim.enable = true;

        # Don't start the LLM server until its model disk is actually mounted (only on the LLM
        # node — the voice node has no llama-cpp service, and a bare unitConfig would otherwise
        # define a phantom unit). Cache-heavy services on other nodes (e.g. WhisperX) add their
        # own RequiresMountsFor=/var/cache in their module.
        systemd.services.llama-cpp.unitConfig.RequiresMountsFor =
          lib.mkIf config.services.llama-cpp.enable
            [ "/var/cache" ];
      }

      (lib.mkIf cfg.relocateNixStore {
        # /nix on the NVMe. neededForBoot → mounted in stage-1 so the store is present before
        # switch-root; the initrd carries the nvme driver (below). /boot stays on eMMC.
        fileSystems."/nix" = {
          device = cfg.nixStoreDevice;
          inherit (cfg) fsType;
          neededForBoot = true;
          options = [ "noatime" ];
        };
        boot.initrd.availableKernelModules = [ "nvme" ];
      })
    ]
  );
}
