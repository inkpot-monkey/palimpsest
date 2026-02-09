{
  inputs,
  pkgs,
  settings,
  self,
  keys,
  ...
}:
{
  imports = [
    inputs.vpsFree.nixosConfigurations.container

    (self + /modules/nixos/common/base.nix)

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
    # ../../modules/nixos/common/nebula.nix

    # ../../modules/nixos/common/listener.nix
    # ../../modules/nixos/common/observability.nix
    # ../../modules/nixos/common/listener.nix
    # ../../modules/nixos/common/observability.nix
    # self.nixosModules.git-annex
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

  # nixpkgs.hostPlatform is now handled by the pkgs instance in flake.nix

  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "prohibit-password";
  users.extraUsers.root.openssh.authorizedKeys.keys = [
    keys.personal.inkpotmonkey
  ];

  systemd.settings.Manager = {
    DefaultTimeoutStartSec = "900s";
  };

  time.timeZone = "Europe/Amsterdam";

  system.stateVersion = "25.11";
}
