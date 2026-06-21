# The feature registry — the SINGLE source of truth for the contract's feature
# vocabulary (ADR-0015, mechanic 2). One entry per feature; every other feature
# surface the contract exposes (the `granted.*` grant options, `featureMeta`,
# `featureGroups`, the user-owned `featureConfig` options, the imported feature
# modules, the derived safe set, and the sops recipients) is a PROJECTION of this
# map — see contract/default.nix. Adding a feature is a single edit here, and the
# keys can never drift across the projections because there is only one set of keys.
#
# Per-entry shape (all fields optional except `grant`):
#   grant         : mkEnableOption description for `custom.users.<u>.granted.<f>`
#   groups        : privileged/host groups the grant confers (clamped in via the
#                   realization). Listed in `privilegedGroups` ⇒ build-time-only.
#   secretBearing : the feature pulls a secret onto a host ⇒ an exposed host may not
#                   be granted it, and it is excluded from the runtime safe set.
#   secretFiles   : stash-relative sops files whose recipient set is DERIVED from the
#                   hosts that grant this feature (self.lib.featureRecipients).
#   execPayload   : the feature runs host-side user-supplied code ⇒ never safe-set
#                   eligible (the inert-payload clause; no feature uses it yet).
#   config        : user-owned option fragment merged into `custom.users.<u>` — the
#                   feature's *parameters* (host-affecting ones aggregate, ADR-0019).
{ lib }:
{
  # gui: desktop environment. Its host effects are two contract-neutral things only —
  # the session-union DECISION (realization → custom.gui.surface) and the non-privileged
  # input groups below. Everything device/package/layout-specific (uinput, keyboard
  # layout, app permits, the display backend) is a HOST binding (gui-desktop.nix + the
  # user's glue), so the contract has no gui *module*. In the safe set: no secret, no
  # privileged group, no exec payload.
  gui = {
    grant = "the GUI feature for this user (host grant)";
    groups = [
      "input"
      "uinput"
      "plugdev"
      "dialout"
    ];
    config = {
      # gui.session: which display session this user logs into. Host-affecting and
      # UNION-aggregated by the realization (ADR-0019) — a Wayland user and an X11
      # user coexist on one seat, each logging into their own. A user declares this;
      # it NEVER sets services.xserver.enable directly.
      gui.session = lib.mkOption {
        type = lib.types.enum [
          "wayland"
          "x11"
        ];
        default = "wayland";
        description = "Display session this user logs into; unioned across granted gui users by the realization.";
      };
    };
  };

  # workstation: privileged host access — the docker/podman/wheel groups. A user can
  # never obtain these by declaring them in identity.extraGroups; only this grant does.
  workstation = {
    grant = "privileged workstation groups for this user (host grant)";
    groups = [
      "docker"
      "podman"
      "wheel"
    ];
  };

  # sudo: administrative (wheel) access and nothing more — the MINIMAL privileged grant.
  # workstation also confers docker/podman; this is for accounts that need sudo without a
  # dev toolchain (e.g. a break-glass admin, or a co-admin user). wheel is privileged, so
  # like workstation it is build-time-only and excluded from the safe set — never a
  # greeter auto-grant. A user can never obtain wheel by declaring it in identity; the
  # clamp drops it (ADR-0015 threat model) and only this grant restores it.
  sudo = {
    grant = "wheel/sudo administrative access for this user (host grant)";
    groups = [ "wheel" ];
  };

  # virtualization: the privileged disk/libvirtd/qemu-libvirtd groups, split out of gui
  # (slice 11) so gui stays in the safe set — these are build-time-only, never auto-
  # granted at a greeter. (kvm is in privilegedGroups but conferred to no user today.)
  virtualization = {
    grant = "privileged virtualization groups for this user (host grant)";
    groups = [
      "disk"
      "qemu-libvirtd"
      "libvirtd"
    ];
  };

  # signing: the user's dedicated NON-admin commit-signing key. Secret-bearing (so the
  # exposed-host ban applies and a greeter never auto-grants it), but the secret rides
  # the USER's home sops decrypted by the user's own key — no host re-key, no host
  # recipients (no secretFiles). See users/inkpotmonkey/home/signing.nix (slice 13).
  signing = {
    grant = "the commit-signing key for this user (host grant)";
    secretBearing = true;
  };
}
