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
    self.nixosProfiles.tailscale
    self.nixosProfiles.monitoring.client
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
