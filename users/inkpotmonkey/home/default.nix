{
  inputs,
  lib,
  config,
  ...
}:

{
  imports = [
    inputs.sops-nix.homeManagerModule
    ../identity.nix

    ./base.nix
    ./shell.nix
    ./git.nix
    ./ssh.nix
    # gui.nix is now conditionally imported in nixos/default.nix for "Lean CLI"
  ];

  options.custom.home.profiles = {
    cli.enable = lib.mkEnableOption "CLI meta-profile (base tools)";
    gui.enable = lib.mkEnableOption "GUI meta-profile (desktop environment)";
    # Individual profile options remain defined for discovery, even if their implementation is in gui.nix
  };

  config = lib.mkMerge [
    # CLI Meta-Profile Definition (The Lean Core)
    (lib.mkIf config.custom.home.profiles.cli.enable {
      custom.home.profiles = {
        base.enable = lib.mkDefault true;
        shell.enable = lib.mkDefault true;
        git.enable = lib.mkDefault true;
        ssh.enable = lib.mkDefault true;
      };
    })

    # The GUI Meta-Profile definition has been moved to gui.nix to keep the CLI core lean.
  ];
}
