{ inputs, ... }:

{
  imports = [
    inputs.impermanence.nixosModules.impermanence
  ];

  # Persistence configuration
  environment.persistence."/persistent" = {
    hideMounts = true;
    directories = [
      {
        directory = "/var/lib/private";
        mode = "0700";
      }
      "/etc/nixos"
      "/var/log"
      "/var/lib/nixos"
    ];
    files = [
      "/etc/machine-id"
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
    ];
  };
}
