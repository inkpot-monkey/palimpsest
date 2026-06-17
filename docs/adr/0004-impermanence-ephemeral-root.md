# Impermanence: ephemeral root, explicitly-persisted directories

Several hosts (notably `kelpy`, `sawtoothShark`, the RK1 nodes) use the `impermanence` input to keep the root filesystem ephemeral and persist only directories declared explicitly via `environment.persistence`. State that isn't declared does not survive a reboot — which is the point: it forces every stateful service to name exactly what it keeps.

The non-obvious consequence, learned the hard way: a persisted dir is an impermanence bind-mount over a root-owned dataset, so a `systemd.tmpfiles` `d … <user>` rule does **not** chown it — the mount wins. A non-root service then can't write to its own `/var/lib/<svc>`. The fix is to use systemd `StateDirectory` (which chowns on every start) and/or declare the persistence entry in attrset form (`{ directory; user; group; mode; }`), not a bare string.

## Consequences

- Adding a stateful service means adding an explicit `environment.persistence` entry; forgetting it means silent data loss on reboot.
- Don't rely on tmpfiles to own a persisted directory for a non-root user.
