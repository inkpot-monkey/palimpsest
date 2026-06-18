# Host-invariant account realization — part of the host↔user contract (ADR-0015,
# mechanic 5). Maps each `custom.users.<u>` to a system account. Powers route
# through *grants*, not raw identity: the display manager / networkmanager come
# from the gui grant rather than an `identity.profile` proxy. (The
# privileged-group clamp on `extraGroups` lands in the next commit.)
{ lib, config, ... }:
let
  users = config.custom.users;
  anyGuiGranted = lib.any (u: u.granted.gui.enable or false) (lib.attrValues users);
in
{
  config = {
    networking.networkmanager.enable = lib.mkIf anyGuiGranted true;
    services.displayManager.sddm = {
      enable = lib.mkIf anyGuiGranted (lib.mkDefault true);
      wayland.enable = lib.mkIf anyGuiGranted (lib.mkDefault true);
    };

    users.users = lib.mapAttrs (_name: u: {
      isNormalUser = true;
      inherit (u.identity) hashedPassword extraGroups;
      description = u.identity.name;
      openssh.authorizedKeys.keys =
        lib.optional (u.identity.sshKey != "") u.identity.sshKey ++ u.identity.trustedKeys;
    }) users;
  };
}
