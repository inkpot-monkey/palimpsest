{ lib, ... }:
{

  config.custom.users.general.identity = {
    profile = lib.mkDefault "gui";
    username = "general";
    hashedPassword = ""; # No password set by default
    name = "General User";
    email = "general@example.com";
    sshKey = ""; # No SSH key set by default
    extraGroups = [
      "networkmanager"
      "wheel"
      "audio"
      "video"
    ];
  };
}
