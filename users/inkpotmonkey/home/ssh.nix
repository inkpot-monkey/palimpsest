{
  config,
  lib,
  ...
}:
{
  options.custom.home.profiles.ssh = {
    enable = lib.mkEnableOption "ssh configuration";
  };

  config = lib.mkIf config.custom.home.profiles.ssh.enable {
    services.ssh-agent.enable = true;

    programs.ssh = {
      enable = true;
      enableDefaultConfig = false;
      matchBlocks."*" = {
        addKeysToAgent = "yes";
      };
    };
  };
}
