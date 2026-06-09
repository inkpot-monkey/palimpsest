{
  config,
  lib,
  options,
  ...
}:
{
  options.custom.home.profiles.ssh = {
    enable = lib.mkEnableOption "ssh configuration";
  };

  config = lib.mkIf config.custom.home.profiles.ssh.enable {
    services.ssh-agent.enable = true;

    # home-manager's ssh module differs across our two pinned inputs: unstable
    # exposes the `settings` API (and deprecates `matchBlocks`), while
    # release-25.11 (the pi hosts) only has `matchBlocks` and no
    # `enableDefaultConfig`. Pick whichever this home-manager actually provides.
    programs.ssh = lib.mkMerge [
      { enable = true; }
      (lib.optionalAttrs (options.programs.ssh ? enableDefaultConfig) {
        enableDefaultConfig = false;
      })
      (
        if options.programs.ssh ? settings then
          { settings."*".AddKeysToAgent = "yes"; }
        else
          { matchBlocks."*".addKeysToAgent = "yes"; }
      )
    ];
  };
}
