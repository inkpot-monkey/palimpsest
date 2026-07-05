{
  pkgs,
  lib,
  inputs,
  self,
  ...
}:
{
  imports = [
    "${inputs.nixpkgs}/nixos/modules/profiles/headless.nix"

    # Profiles
    self.nixosProfiles.bundle
    self.nixosProfiles.pi-bundle
  ];

  custom.profiles = {
    pi.enable = true;
    base.enable = true;
    ssh.enable = true;
    sudo.enable = true;
    wireless.enable = true;
    hifiberry.enable = true;
    hifi.enable = true;
    tailscale = {
      enable = true;
      advertiseSubnet = "192.168.1.0/24";
      tags = [ "tag:server" ];
    };
    monitoring-client.enable = true;
    monitoring-smartctl.enable = true;
    backup.enable = true;
    blocky.enable = true;
  };

  # ZFS is a stray default and nothing on this audio node uses it — that alone is
  # reason to drop it. It also drags in the zfs-kernel module, which builds against
  # the kernel's `dev` output; that output is uncached upstream (nixos-raspberrypi
  # caches only `out`). `just cache-kernel porcupineFish` now pushes `dev` to our own
  # cache, so this no longer *forces* a full kernel recompile — but that relief is
  # conditional (it lapses on every kernel-pin bump until cache-kernel is re-run) and
  # the zfs module itself is still an uncached from-source build. So: keep it off.
  boot.supportedFilesystems.zfs = lib.mkForce false;

  services.restic.backups.daily.paths = [
    "/var/lib"
    "/home/inkpotmonkey"
  ];

  sops.age.sshKeyPaths = [
    "/etc/ssh/ssh_host_ed25519_key"
  ];

  environment.systemPackages = with pkgs; [
    git
  ];

  networking.hostName = "porcupineFish";

  system.stateVersion = "25.11";

  hardware.enableRedistributableFirmware = true;
}
