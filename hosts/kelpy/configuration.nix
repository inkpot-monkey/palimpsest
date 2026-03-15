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

    self.nixosProfiles.bundle
  ];

  custom.profiles = {
    base.enable = true;
    impermanence.enable = true;
    tailscale = {
      enable = true;
      tags = [ "tag:server" ];
    };
    server.enable = true;
    proxy.enable = true;
    backup.enable = true;
    monitoring-server.enable = true;
    monitoring-client.enable = true;
    mail = {
      enable = true;
      domain = "palebluebytes.xyz";
    };
    matrix.enable = true;
    paperless.enable = true;
    litellm.enable = true;
    transmission.enable = true;
    blocky.enable = true;
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

  nixpkgs.hostPlatform = "x86_64-linux";

  environment.systemPackages = with pkgs; [
    git
  ];

  system.stateVersion = "25.11";
}
