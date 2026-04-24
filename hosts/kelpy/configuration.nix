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
    inputs.openclaw-nix.nixosModules.openclaw-gateway

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
      domain = "palebluebytes.space";
    };
    matrix.enable = true;
    paperless.enable = true;
    litellm.enable = true;
    transmission.enable = true;
    blocky.enable = true;
    media = {
      enable = true;
      transcriptionServer.address = "100.95.39.9";
    };
  };

  services.openclaw-gateway = {
    enable = true;
    # Connect to the local LiteLLM service
    port = 8001;
  };

  networking = {
    inherit (settings.nodes.kelpy) hostName domain;
  };

  services.restic.backups.daily.paths = [ "/persistent" ];

  nixpkgs = {
    hostPlatform = "x86_64-linux";
    config.permittedInsecurePackages = [
      "openclaw-2026.2.26"
      "beekeeper-studio-5.5.7"
    ];
  };

  environment.systemPackages = with pkgs; [
    git
  ];

  system.stateVersion = "25.11";
}
