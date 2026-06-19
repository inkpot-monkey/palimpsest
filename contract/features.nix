# Feature / capability vocabulary that host grants key on (ADR-0015, mechanic 2).
# A host grants a user's feature via `custom.users.<user>.granted.<feature>`;
# ungranted is default-closed. Populated per feature as the migration proceeds
# (slice 02 adds the first, `gui`). Returns option fragments keyed by feature.
{ lib }:
{
  # gui: desktop environment — display manager, GUI home modules, hardware groups.
  gui.enable = lib.mkEnableOption "the GUI feature for this user (host grant)";
  # restic: user-level backup. Secret-bearing (see contract/default.nix featureMeta):
  # an exposed host may not be granted it.
  restic.enable = lib.mkEnableOption "the restic backup feature for this user (host grant)";
  # workstation: privileged host access — confers the docker/podman/wheel groups
  # (contract/default.nix featureGroups). A user can never obtain these by merely
  # declaring them in identity.extraGroups; only this grant confers them.
  workstation.enable = lib.mkEnableOption "privileged workstation groups for this user (host grant)";
  # virtualization: the privileged disk/libvirtd/qemu-libvirtd groups (contract
  # featureGroups). Split out of gui (slice 11) so gui stays in the safe set — these
  # are privileged and build-time-only, never auto-granted at a greeter.
  virtualization.enable = lib.mkEnableOption "privileged virtualization groups for this user (host grant)";
}
