# Host-invariant account realization — part of the host↔user contract (ADR-0015,
# mechanic 5). Maps each `custom.users.<u>` to a system account. Powers route
# through *grants*, not raw identity:
#   - the display manager / networkmanager come from the gui grant, not a profile;
#   - **privileged group membership is clamped**: a user's self-declared
#     `identity.extraGroups` is untrusted input, so privileged groups (docker,
#     wheel, …) are filtered out of it and conferred ONLY by a feature grant
#     (contract featureGroups). A user can never escalate by listing `docker` in
#     its own identity; a host must grant `workstation`.
#
# Audit (ADR-0015 threat model) — which identity fields confer host-side power:
#   name/email/gmail/username .... inert (descriptive)
#   sshKey/trustedKeys ........... login as that user (public keys; the user's call)
#   hashedPassword ............... login credential (one-way hash)
#   profile ...................... no longer gates anything (grants do); kept transitional
#   extraGroups .................. CLAMPED here — privileged groups need a grant
#   granted.<feature> ............ the host's decision; the only source of privilege
# NOTE: kelpy (exposed) currently receives `workstation` (docker/podman/wheel) via
# the inkpotmonkey cli variant — visible now, and revocable with one line; the
# exposed-host agent box arguably should not have it. general/eyeofalligator still
# declare `wheel` in identity and will be clamped until migrated to a grant (neither
# is on a working host today).
{
  lib,
  config,
  self,
  ...
}:
let
  inherit (self.contract) privilegedGroups featureGroups;
  users = config.custom.users;
  anyGuiGranted = lib.any (u: u.granted.gui.enable or false) (lib.attrValues users);

  grantedNames = u: lib.filter (f: u.granted.${f}.enable or false) (lib.attrNames u.granted);
  # Privileged groups earned from the features granted to this user.
  grantedGroups = u: lib.concatMap (f: featureGroups.${f} or [ ]) (grantedNames u);
  # Self-declared groups with privileged ones clamped out (untrusted input).
  safeDeclared = u: lib.filter (g: !lib.elem g privilegedGroups) u.identity.extraGroups;
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
      inherit (u.identity) hashedPassword;
      extraGroups = lib.unique (safeDeclared u ++ grantedGroups u);
      description = u.identity.name;
      openssh.authorizedKeys.keys =
        lib.optional (u.identity.sshKey != "") u.identity.sshKey ++ u.identity.trustedKeys;
    }) users;
  };
}
