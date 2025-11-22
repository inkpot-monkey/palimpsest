{ inputs, self, ... }:
{
  imports = [
    inputs.sops-nix.nixosModules.sops
  ];

  sops = {
    # Both the user's SSH key and the system's SSH host key
    age.sshKeyPaths = [
      "/home/inkpotmonkey/.ssh/id_ed25519" # User key
      "/etc/ssh/ssh_host_ed25519_key" # System key
    ];

    defaultSopsFile = self + "/secrets/secrets.yaml";
  };
}
