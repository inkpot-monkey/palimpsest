{
  inputs,
  pkgs,
  settings,
  self,
  outputs,
  ...
}:
{
  imports = [
    inputs.vpsFree.nixosConfigurations.container

    ../common/nix.nix

    ./secrets.nix
    ./impermanence.nix
    ./proxy.nix

    ./matrix/matrix.nix
    # ./paperless.nix
    # ./immich.nix
    # ./searx.nix
    # ./archivebox.nix
    # ./actual-budget.nix
    # ./actual-budget.nix
    ./mail.nix

    # ../potbelliedSeahorse/configuration.nix
    # ../common/nebula.nix

    # ../common/listener.nix
    # ../common/observability.nix
    # ../common/listener.nix
    # ../common/observability.nix
    # outputs.nixosModules.git-annex
    # ./git-annex.nix
  ];

  networking = {
    inherit (settings.host) hostName;
    domain = "palebluebytes.xyz";
  };

  environment.systemPackages = with pkgs; [
    git-annex
    git
    ripgrep
    fd
    gnupg
  ];

  programs.git.config.safe.directory = [
    "/var/lib/git-annex/gateway"
    "/var/lib/git-annex/backup"
  ];

  nixpkgs.hostPlatform = "x86_64-linux";

  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "yes";
  users.extraUsers.root.openssh.authorizedKeys.keys = [
    "<SCRUBBED_SSH_KEY>"
  ];

  systemd.settings.Manager = {
    DefaultTimeoutStartSec = "900s";
  };

  time.timeZone = "Europe/Amsterdam";

  system.stateVersion = "25.05";
}
