# Shared configuration for both Turing Pi RK1 (RK3588, 32 GB) nodes.
# Per-node differences (hostname + model) are set in hosts/default.nix.
{ inputs, self, ... }:
{
  imports = [
    # Hardware: boot, u-boot, mainline kernel, device tree, root fileSystem.
    inputs.nixos-turing-rk1.nixosModules.turing-rk1

    # RK1-specific local modules (not shared profiles — only these nodes serve LLMs / use NVMe).
    ./llm.nix # local llama.cpp LLM server (custom.rk1.llm)
    ./nvme.nix # optional NVMe model-cache storage (inert until custom.rk1.nvme.enable = true)

    self.nixosProfiles.base
    self.nixosProfiles.nixConfig # enabled transitively by base
    self.nixosProfiles.sops # enabled transitively by base
    self.nixosProfiles.impermanence # option read by tailscale (left disabled)
    self.nixosProfiles.ssh
    self.nixosProfiles.sudo
    self.nixosProfiles.tailscale
  ];

  custom.profiles = {
    base.enable = true;
    ssh.enable = true;
    sudo.enable = true;
    tailscale = {
      enable = true;
      tags = [ "tag:server" ];
    };
  };

  # Local LLM server (model set per-node in hosts/default.nix).
  custom.rk1.llm.enable = true;

  # Declared users are authoritative: removes the GiyoMoon base-image `nixos`/`turing`
  # account on the first switch. Login is key-only SSH as inkpotmonkey (see profiles/ssh.nix);
  # inkpotmonkey's hashedPassword + ssh key come from secrets/identities.nix.
  users.mutableUsers = false;
  users.users.root.hashedPassword = "!"; # lock the root account (no password login)

  nixpkgs.hostPlatform = "aarch64-linux";

  system.stateVersion = "25.11";
}
