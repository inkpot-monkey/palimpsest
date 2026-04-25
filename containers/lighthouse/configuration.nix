{ inputs, self, ... }:
{
  imports = [
    inputs.sops-nix.nixosModules.sops
    (self + /modules/nixos/common/nebula.nix)
  ];

  sops = {
    # Both the user's SSH key and the system's SSH host key
    age.sshKeyPaths = [
      "/etc/ssh/ssh_host_ed25519_key" # System key
    ];

    defaultSopsFile = self.lib.getSecretPath "nebula.yaml";
  };

  services.nebula.networks.mesh = {
    # Update paths to match the bind mount
    isLighthouse = true;
    lighthouses = [ ];
    lighthouse.dns = {
      enable = true;
      host = "192.168.100.1";
    };
    staticHostMap = { };
    firewall.allowedUDPPorts = [
      4242
      5353
    ];
    hostName = "lighthouse";
  };

  system.stateVersion = "25.05";
}
