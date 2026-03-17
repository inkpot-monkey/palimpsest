{
  lib,
  config,
  ...
}:

{
  imports = [
    ./cli.nix
    ./gui.nix
  ];

  options.custom.home.profiles = {
    cli.enable = lib.mkEnableOption "CLI meta-profile (base tools)";
    gui.enable = lib.mkEnableOption "GUI meta-profile (desktop environment)";
  };

  config = lib.mkMerge [
    (lib.mkIf config.custom.home.profiles.cli.enable {
      custom.home.profiles = {
        base.enable = lib.mkDefault true;
        shell.enable = lib.mkDefault true;
        git.enable = lib.mkDefault true;
        ssh.enable = lib.mkDefault true;
      };
    })
  ];
}
