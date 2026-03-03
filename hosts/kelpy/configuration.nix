{
  inputs,
  pkgs,
  self,
  settings,
  ...
}:
{
  imports = [
    inputs.vpsFree.nixosConfigurations.container

    self.nixosProfiles.base
    self.nixosProfiles.impermanence
    self.nixosProfiles.server
    self.nixosProfiles.sops
    self.nixosProfiles.mail
    self.nixosProfiles.matrix
    self.nixosProfiles.proxy
    self.nixosProfiles.podman
    self.nixosProfiles.tailscale
    self.nixosProfiles.paperless
    self.nixosProfiles.litellm
    self.nixosProfiles.transmission
    self.nixosProfiles.monitoring.server
    self.nixosProfiles.monitoring.client

    # self.nixosProfiles.affine
    # ./git-annex.nix
  ];

  # Sops secrets configuration
  sops = {
    age.sshKeyPaths = [
      "/home/inkpotmonkey/.ssh/id_ed25519" # User key
      "/etc/ssh/ssh_host_ed25519_key" # System key
    ];
  };

  networking = {
    inherit (settings.nodes.kelpy) hostName domain;
  };

  profiles.mail.domain = "palebluebytes.xyz";

  nixpkgs.hostPlatform = "x86_64-linux";

  environment.systemPackages = with pkgs; [
    git
    ripgrep
    fd
    jq
  ];

  environment.persistence."/persistent" = {
    hideMounts = true;
    directories = [
      "/etc/nixos"
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/stalwart-mail"
      "/var/lib/acme"
    ];
  };

  systemd.settings.Manager = {
    DefaultTimeoutStartSec = "900s";
  };

  system.stateVersion = "25.11";
}
