{
  config,
  lib,
  ...
}:

let
  cfg = config.custom.profiles.direnv;
in
{
  options.custom.profiles.direnv = {
    enable = lib.mkEnableOption "direnv configuration";
  };

  config = lib.mkIf cfg.enable {
    programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
      loadInNixShell = true;
    };
  };
}
