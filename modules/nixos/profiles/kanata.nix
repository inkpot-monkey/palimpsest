# Kanata keyboard-remap, as HOST config (ADR-0018, slice 11). kanata runs as a
# privileged system service and its keymap uses `danger-enable-cmd` + `(cmd …)` to
# run shell — an executable payload that must NOT ride a safe-set (greeter-grantable)
# user feature. So it is host config a host opts into, not a user request. Making the
# keymap travel *with* a user is the deferred, harder problem (issue 18).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.custom.profiles.kanata;
in
{
  options.custom.profiles.kanata = {
    enable = lib.mkEnableOption "kanata keyboard remapping (laptop keyboard; cmd-enabled keymap)";
  };

  config = lib.mkIf cfg.enable {
    # kanata needs the uinput device; assert it here so the profile is self-sufficient
    # even on a host where the gui feature module hasn't enabled it.
    hardware.uinput.enable = true;

    services.kanata = {
      enable = true;
      package = pkgs.kanata-with-cmd;
      keyboards.default = {
        configFile = ./kanata.kbd;
        extraDefCfg = "process-unmapped-keys yes";
      };
    };

    systemd.services.kanata-default = {
      path = [ pkgs.brightnessctl ];
      serviceConfig.SupplementaryGroups = [
        "input"
        "uinput"
        "video"
      ];
    };
  };
}
