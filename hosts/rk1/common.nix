# Shared configuration for both Turing Pi RK1 (RK3588, 32 GB) nodes.
# Per-node differences (hostname + model) are set in hosts/default.nix.
{ inputs, self, ... }:
{
  imports = [
    # Hardware: boot, u-boot, mainline kernel, device tree, root fileSystem.
    inputs.nixos-turing-rk1.nixosModules.turing-rk1

    self.nixosProfiles.base
    self.nixosProfiles.nixConfig # enabled transitively by base
    self.nixosProfiles.sops # enabled transitively by base
    self.nixosProfiles.impermanence # option read by tailscale (left disabled)
    self.nixosProfiles.ssh
    self.nixosProfiles.sudo
    self.nixosProfiles.tailscale
    self.nixosProfiles.local-llm
  ];

  custom.profiles = {
    base.enable = true;
    ssh.enable = true;
    sudo.enable = true;
    tailscale = {
      enable = true;
      tags = [ "tag:server" ];
    };
    localLlm.enable = true; # model set per-node in hosts/default.nix
  };

  nixpkgs.hostPlatform = "aarch64-linux";

  system.stateVersion = "25.11";
}
