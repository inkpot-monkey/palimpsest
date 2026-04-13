{ lib, ... }:
{

  config.custom.users.inkpotmonkey.identity = {
    profile = lib.mkForce "gui";
    username = "inkpotmonkey";
    hashedPassword = "<SCRUBBED_PASSWORD>";
    name = "thomassdk";
    email = "<SCRUBBED_EMAIL>";
    sshKey = "<SCRUBBED_SSH_KEY>";
    extraGroups = [
      "podman"
      "docker"
      "networkmanager"
      "audio"
      "video"
      "wheel"
      "i2c"
      "systemd-journal"
    ];
  };
}
