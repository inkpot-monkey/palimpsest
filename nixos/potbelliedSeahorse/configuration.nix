# The pot bellied seahorse has one role, to let the other fish talk
{ self, inputs, ... }:
{

  imports = [
    inputs.sops-nix.nixosModules.sops
    inputs.nixos-hardware.nixosModules.raspberry-pi-4
    inputs.disko.nixosModules.disko
    ./disk-config.nix
    ../common/nebula.nix
  ];

  sops = {
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    defaultSopsFile = self + "/secrets/secrets.yaml";
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
  networking.hostName = "lighthouse";

  system.stateVersion = "25.11";
}
