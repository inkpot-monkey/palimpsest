{
  pkgs,
  inputs,
  self,
  ...
}:
{
  imports = [
    "${inputs.nixpkgs}/nixos/modules/profiles/headless.nix"

    self.nixosProfiles.pi
    self.nixosProfiles.base
    self.nixosProfiles.server
    self.nixosProfiles.sops
    self.nixosProfiles.wireless
    self.nixosProfiles.hifiberry
    self.nixosProfiles.hifi
    self.nixosProfiles.tailscale
    self.nixosProfiles.monitoring.client
    self.nixosProfiles.monitoring.smartctl
    self.nixosProfiles.backup
  ];

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

  services.mopidy.settings.audio.output = "alsasink device=hw:0,0";
}
