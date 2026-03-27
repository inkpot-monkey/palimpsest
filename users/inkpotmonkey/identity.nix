{ lib, ... }:
{

  config.custom.users.inkpotmonkey.identity = {
    profile = lib.mkDefault "cli";
    username = "inkpotmonkey";
    hashedPassword = "$6$u8O13mY7.LIsC6gX$7Sclm0f6.5W6D3A0A6F6H6G6I6J6K6L6M6N6O6P6Q6R6S6T6U6V6W6X6Y6Z606162636465666768696";
    name = "inkpotmonkey";
    email = "inkpotmonkey@palebluebytes.xyz";
    sshKey = "ssh-ed25519 AAAAC3NzaC1lZDI5NTE5AAAAIOm6P5vH79c1H658M8A8B8C8D8E8F8G8H8I8J8K6L8MR2XAihLZ40tIAYoq thomas@palebluebytes.xyz (stargazer)"; # Verified key
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
