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
  ]
  ++ (with self.nixosProfiles; [
    # Capabilities
    base
    audio
    gui-base
    backup
    direnv
    fonts
    gaming
    impermanence
    litellm
    sops
    monitoring.client
  ]);

  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  networking.hostName = "sawtoothShark";
  nixpkgs.hostPlatform = "x86_64-linux";

  system.stateVersion = "25.11";
}
