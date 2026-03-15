{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.custom.profiles.zsa;
in
{
  options.custom.profiles.zsa = {
    enable = lib.mkEnableOption "ZSA keyboard support (Wally)";
  };

  config = lib.mkIf cfg.enable {
    hardware.keyboard.zsa.enable = true;
    environment.systemPackages = [ pkgs.wally-cli ];
  };
}
