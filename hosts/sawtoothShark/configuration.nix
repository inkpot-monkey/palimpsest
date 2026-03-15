{
  self,
  inputs,
  ...
}:
{
  imports = [
    # Hardware
    ./hardware-configuration.nix
    ./dell-latitude.nix

    inputs.sops-nix.nixosModules.sops
    inputs.home-manager.nixosModules.home-manager
    self.users.general
    ./../../users/general/plasma.nix

    # Profiles
    self.nixosProfiles.bundle
  ];

  custom.profiles = {
    base.enable = true;
    audio.enable = true;
    gui-base.enable = true;
    backup.enable = true;
    direnv.enable = true;
    fonts.enable = true;
    gaming.enable = true;
    impermanence.enable = true;
    litellm.enable = true;
    monitoring-client.enable = true;
  };

  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  services.restic.backups.daily.paths = [ "/persistent" ];

  networking.hostName = "sawtoothShark";
  nixpkgs.hostPlatform = "x86_64-linux";

  system.stateVersion = "25.11";
}
