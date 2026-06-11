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

  # ZFS is a stray default (nothing here uses it) and an audio node has no need for it.
  # More importantly it drags in zfs-kernel, which needs the kernel's `dev` output — that
  # output isn't in nixos-raspberrypi's cache, so leaving zfs on would force a full
  # from-source kernel compile on every build/deploy. Dropping it lets the (cached) kernel
  # substitute instead.
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
    alsa-utils
  ];

  hardware.alsa.enablePersistence = true;

  networking.hostName = "porcupineFish";

  system.stateVersion = "25.11";

  hardware.enableRedistributableFirmware = true;
}
