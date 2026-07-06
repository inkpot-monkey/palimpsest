# Impermanence (ephemeral tmpfs root) for porcupineFish.
#
# DEPLOYED & VERIFIED 2026-07-06 — porcupineFish is the fleet's first
# nixos-raspberrypi impermanence host; the boot chain is adapted from the rk1 pattern
# (hosts/rk1/common.nix). It booted cleanly both warm and from a cold power-on, with
# all mounts correct and /var/lib/alsa/asound.state restored.
#
# STILL BOOT-CRITICAL if you change any of the fileSystems / persistence below: deploy
# with `just deployBoot porcupineFish` (a `boot` generation) + ONE reboot — NOT `switch`
# (you cannot remount / to tmpfs on the running system) — and ideally with console
# access, since a bad boot needs the extlinux menu to recover.
#
# What was verified at bring-up (re-check these if you touch the boot config):
#   1. root= kernelParam. nixos-raspberrypi does NOT emit a `root=` (unlike rk1's
#      turing-rk1 module, which forced one and needed a mkOverride to strip it) — it
#      derives the root from the initrd's neededForBoot mounts, so tmpfs root works with
#      no override. Confirmed absent from the generated /boot/extlinux/extlinux.conf.
#   2. /boot durability. extlinux.conf + the kernels (/boot/nixos/*) live on the root,
#      so /boot is persisted below. /boot resolves to NIXOS_SD:/boot whether accessed
#      directly or via the persist bind-mount, so bootloader installs stay durable.
#   3. Fallback. NIXOS_SD is left untouched, so the previous ext4-root generations stay
#      in the extlinux menu and still boot — the recovery path (needs console access).
#
# NOTE: impermanence does NOT affect audio. The I²S clock wedge that recurred during
# bring-up is a separate SoC hardware issue (cold-cycle to clear) — see
# RUNBOOK-audio-silence.md. Impermanence was exonerated.
{
  lib,
  ...
}:
{
  custom.profiles.impermanence.enable = true;

  # tmpfs root — wiped every boot. The existing ext4 root (NIXOS_SD) is remounted as
  # /persistent; only the state declared below survives. `size` is a cap, not a
  # reservation: actual usage on this headless audio node is tens of MB (builds run
  # on the rk1b offloader, not here).
  fileSystems."/" = lib.mkForce {
    device = "none";
    fsType = "tmpfs";
    options = [
      "defaults"
      "size=1G"
      "mode=755"
    ];
  };

  fileSystems."/persistent" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
    neededForBoot = true;
  };

  # The Nix store already lives at NIXOS_SD:/nix = /persistent/nix; bind it so it is
  # reachable from the tmpfs root. neededForBoot → mounted in stage-1.
  fileSystems."/nix" = {
    device = "/persistent/nix";
    fsType = "none";
    options = [ "bind" ];
    depends = [ "/persistent" ];
    neededForBoot = true;
  };

  # /boot/firmware is a separate FAT partition (label FIRMWARE), already persistent
  # by virtue of being its own partition — left as pi/default.nix defines it.

  environment.persistence."/persistent" = {
    directories = [
      # extlinux + kernels live on the root fs, so /boot MUST persist or the box is
      # unbootable after the first wipe (u-boot reads extlinux.conf from here).
      "/boot"

      # The PCM512x hardware mixer state (asound.state). hardware.alsa.enablePersistence
      # (set in the hifiberry profile) writes here on shutdown and restores on boot;
      # without this entry the ephemeral root would discard it every reboot, silently
      # defeating the persistence. This is the concrete answer to "does the DAC mixer
      # state need impermanence integration?" — yes, exactly this line.
      "/var/lib/alsa"

      # inkpotmonkey's home. Small, but restic treats it as stateful (see the host's
      # services.restic backup paths), so persist it to avoid silent loss on reboot.
      # Attrset form so the persisted dataset is owned by the user, not root (ADR-0004:
      # a persisted dir is a bind-mount that tmpfiles will NOT chown).
      {
        directory = "/home/inkpotmonkey";
        user = "inkpotmonkey";
        group = "users";
        mode = "0700";
      }
    ];
  };

  # Deliberately NOT persisted: /var/cache/spotifyd (spotifyd re-advertises over
  # zeroconf and re-authenticates on connect, so its cache is safe to lose) and the
  # node-exporter textfiles / watchdog counter (regenerated on the next event).
}
