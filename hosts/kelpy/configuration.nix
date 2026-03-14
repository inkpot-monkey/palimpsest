{
  inputs,
  pkgs,
  self,
  settings,
  ...
}:
{
  imports = [
    inputs.vpsFree.nixosModules.containerUnstable

    self.nixosProfiles.base
    self.nixosProfiles.impermanence
    self.nixosProfiles.tailscale
    self.nixosProfiles.server
    self.nixosProfiles.sops
    self.nixosProfiles.proxy
    self.nixosProfiles.backup

    self.nixosProfiles.monitoring.server
    self.nixosProfiles.monitoring.client

    self.nixosProfiles.mail
    self.nixosProfiles.matrix

    self.nixosProfiles.paperless
    self.nixosProfiles.litellm
    self.nixosProfiles.transmission
    self.nixosProfiles.blocky

    # self.nixosProfiles.affine
    # ./git-annex.nix
  ];

  custom.services.tailscale = {
    enable = true;
    tags = [ "tag:server" ];
  };

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

  services.restic.backups.daily.paths = [ "/persistent" ];

  profiles.mail.domain = "palebluebytes.xyz";

  nixpkgs.hostPlatform = "x86_64-linux";

  environment.systemPackages = with pkgs; [
    git
    ripgrep
    fd
    jq
  ];

  systemd.settings.Manager = {
    DefaultTimeoutStartSec = "900s";
  };

  system.stateVersion = "25.11";
}
