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
# An account that declares a privileged group (e.g. `wheel`) in its identity does NOT get
# it unless a grant confers it — so a host that wants such an account to keep that power
# MUST grant the matching feature (e.g. `sudo`/`workstation`). The host repo's grant matrix
# is where those decisions live; this module only enforces the rule.
#
# Closes over its contract data (privilegedGroups, featureGroups) rather than reaching
# through the consumer's `self` (ADR-0020): contract/default.nix applies this with the
# registry-derived values, so the shipped module depends on neither `self` nor `inputs`
# — only the NixOS module args. This is what lets the contract become a standalone flake.
{ privilegedGroups, featureGroups }:
{
  lib,
  config,
  ...
}:
let
  users = config.custom.users;
  # The gui-session union (ADR-0019): the host display surface is derived from
  # every *granted* gui user's session preference, not from any one user writing a
  # raw host singleton. A single-seat host can therefore offer both session types
  # and each user logs into their own (stock SDDM remembers the choice per user).
  guiUsers = lib.filter (u: u.granted.gui.enable or false) (lib.attrValues users);
  anyGuiGranted = guiUsers != [ ];
  guiSessions = map (u: u.gui.session) guiUsers;
  anyWayland = lib.elem "wayland" guiSessions;
  anyX11 = lib.elem "x11" guiSessions;

  grantedNames = u: lib.filter (f: u.granted.${f}.enable or false) (lib.attrNames u.granted);
  # Privileged groups earned from the features granted to this user.
  grantedGroups = u: lib.concatMap (f: featureGroups.${f} or [ ]) (grantedNames u);
  # Self-declared groups with privileged ones clamped out (untrusted input).
  safeDeclared = u: lib.filter (g: !lib.elem g privilegedGroups) u.identity.extraGroups;
in
{
  # The session-union DECISION (ADR-0019), as neutral data — NOT a display backend.
  # The contract decides which sessions the host's shared display surface must offer
  # (the union over granted gui users' preferences, so two users with different
  # sessions coexist on one seat). A host-side display binding (e.g. an SDDM/Plasma or
  # GDM/GNOME one) reads this and renders it; the contract stays desktop-environment-
  # agnostic (ADR-0021 review finding 2).
  options.custom.gui.surface = {
    enabled = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Some gui user is granted on this host — a shared display surface is needed.";
    };
    wayland = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Some granted gui user wants a Wayland session, so the host must offer one.";
    };
    x11 = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Some granted gui user wants an X11 session, so the host must offer one.";
    };
  };

  config = {
    custom.gui.surface = {
      enabled = anyGuiGranted;
      wayland = anyWayland;
      x11 = anyX11;
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
