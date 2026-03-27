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
