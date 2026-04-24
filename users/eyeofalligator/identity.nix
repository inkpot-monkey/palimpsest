{ inputs, lib, ... }:
let
  # Load user identities from secrets if available
  secretsIdentities =
    if builtins.pathExists (inputs.secrets + "/identities.nix") then
      import (inputs.secrets + "/identities.nix")
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
  config.custom.users.eyeofalligator.identity = {
    username = "eyeofalligator";
    name = getIdent "eyeofalligator" "name" "";
    email = getIdent "eyeofalligator" "email" "";
    sshKey = getIdent "eyeofalligator" "sshKey" "";
    hashedPassword = getIdent "eyeofalligator" "hashedPassword" "";
    profile = "gui";

    extraGroups = [
      "networkmanager"
      "audio"
      "video"
      "wheel"
      "systemd-journal"
    ];
  };
}
