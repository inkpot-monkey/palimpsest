# Feature / capability vocabulary that host grants key on (ADR-0015, mechanic 2).
# A host grants a user's feature via `custom.users.<user>.granted.<feature>`;
# ungranted is default-closed. Populated per feature as the migration proceeds
# (slice 02 adds the first, `gui`). Returns option fragments keyed by feature.
{ lib }:
{
  # gui: desktop environment — display manager, GUI home modules, hardware groups.
  gui.enable = lib.mkEnableOption "the GUI feature for this user (host grant)";
}
