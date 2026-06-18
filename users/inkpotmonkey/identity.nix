{ lib, self, ... }:
let
  # Load user identities from secrets if available
  secretsIdentities =
    if builtins.pathExists (self.lib.getSecretPath "identities.nix") then
      import (self.lib.getSecretPath "identities.nix")
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
    name = getIdent "inkpotmonkey" "name" "";
    email = getIdent "inkpotmonkey" "email" "";
    gmail = getIdent "inkpotmonkey" "gmail" "";
    sshKey = getIdent "inkpotmonkey" "sshKey" "";
    hashedPassword = getIdent "inkpotmonkey" "hashedPassword" "";

    # Only non-privileged groups belong in identity (untrusted data). The
    # privileged groups (docker/podman/wheel) now come from the `workstation`
    # grant — see contract/realization.nix and users/inkpotmonkey/default.nix.
    extraGroups = [
      "networkmanager"
      "audio"
      "video"
      "i2c"
      "systemd-journal"
    ];
  };
}
