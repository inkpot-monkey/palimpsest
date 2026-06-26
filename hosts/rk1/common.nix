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
    # Home Assistant + Wyoming voice is now the shared `homeassistant` profile (in the
    # bundle below); rk1b enables it via custom.profiles.homeassistant in hosts/default.nix.

    # The same kitchen-sink bundle every other host uses. Features stay OFF unless toggled
    # in `custom.profiles` below; disabled profiles are mkIf-gated no-ops, so importing the
    # whole bundle is behaviour-neutral versus the old à-la-carte list (verified: identical
    # system fingerprint — same packages, etc entries, systemd units, enable flags) and it
    # removes the manual transitive-import tracking (e.g. tailscale reading
    # custom.profiles.impermanence.enable). See docs/adr/0013.
    self.nixosProfiles.bundle
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

  hardware.deviceTree.enable = true;

  # The local LLM server is enabled per-node in hosts/default.nix: rk1a serves the general
  # MoE; rk1b is voice-only (Home Assistant) and leaves the LLM off to free RAM/disk.

  # Declared users are authoritative: removes the GiyoMoon base-image `nixos`/`turing`
  # account on the first switch. Login is key-only SSH as inkpotmonkey (see profiles/ssh.nix);
  # inkpotmonkey's hashedPassword + ssh key come from secrets/identities.nix.
  users.mutableUsers = false;
  users.users.root.hashedPassword = "!"; # lock the root account (no password login)

  nixpkgs.hostPlatform = "aarch64-linux";

  system.stateVersion = "25.11";
}
