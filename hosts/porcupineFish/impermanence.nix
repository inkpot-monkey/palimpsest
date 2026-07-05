# Impermanence (ephemeral tmpfs root) for porcupineFish.
#
# ⚠️  STAGED, NOT YET DEPLOYED — BOOT-CRITICAL. porcupineFish would be the first
# nixos-raspberrypi host in the fleet to run impermanence, so the boot chain below
# is adapted from the proven rk1 pattern (hosts/rk1/common.nix) but is NOT yet
# verified on this hardware. Deploy ONLY with console access (monitor+keyboard or
# serial) and an SD reader on hand, using `just deployBoot porcupineFish` (a `boot`
# generation) followed by ONE reboot — NOT `switch` (you cannot remount / to tmpfs
# on the running system).
#
# DEPLOY CHECKLIST — verify each on the first tmpfs boot:
#   1. root= kernelParam. The extlinux generator derives kernelParams from
#      fileSystems."/". With a tmpfs root it must NOT emit a stale `root=/dev/...`.
#      rk1's turing-rk1 module force-set one and had to strip it with
#      `boot.kernelParams = lib.mkOverride 49 [ ... ]`. If nixos-raspberrypi does the
#      same, add the equivalent override here. Inspect the generated
#      /boot/extlinux/extlinux.conf before rebooting.
#   2. /boot durability. extlinux.conf + the kernels (/boot/nixos/*) live on the
#      now-tmpfs root, so /boot is persisted below — confirm the bootloader install
#      lands on /persistent and survives a reboot.
#   3. Fallback. NIXOS_SD is left untouched, so the previous ext4-root generation
#      stays in the extlinux menu and still boots — that is the recovery path if the
#      tmpfs generation fails. Selecting it needs console access.
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
