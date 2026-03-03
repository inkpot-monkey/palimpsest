# The pot bellied seahorse has one role, to let the other fish talk
{ self, inputs, ... }:
{

  imports = [
    self.nixosProfiles.sops
    inputs.nixos-hardware.nixosModules.raspberry-pi-4
    inputs.disko.nixosModules.disko

    self.nixosProfiles.nebula

    ./disk-config.nix
  ];

  sops = {
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  };

  services.nebula.networks.mesh = {
    isLighthouse = true;
    lighthouses = [ ];
    lighthouse.dns = {
      enable = true;
      host = "192.168.100.1";
    };
  };

  # should change eventually
  networking.hostName = "potbelliedSeahorse";
  nixpkgs.hostPlatform = "aarch64-linux";

  system.stateVersion = "25.11";

  nixpkgs.config.allowBroken = true;
}
