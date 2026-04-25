{ lib, ... }:
let
  # Load user identities from secrets if available
  secretsIdentities =
    if builtins.pathExists (../../secrets + "/identities.nix") then
      import (../../secrets + "/identities.nix")
    else
      { };

  # Helper to get identity data with a fallback
  getIdent =
    name: field: default:
    if lib.attrByPath [ name field ] null secretsIdentities != null then
      secretsIdentities.${name}.${field}
    else
      default;
in
{
  config.custom.users.inkpotmonkey.identity = {
    username = "inkpotmonkey";
    name = getIdent "inkpotmonkey" "name" "NixOS User";
    email = getIdent "inkpotmonkey" "email" "user@example.com";
    sshKey = getIdent "inkpotmonkey" "sshKey" "";
    hashedPassword = getIdent "inkpotmonkey" "hashedPassword" "";

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
