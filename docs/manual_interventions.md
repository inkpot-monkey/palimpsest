# Manual Interventions and Non-Nix-Managed Settings

This document lists settings, configurations, and maintenance tasks that cannot be controlled or resolved solely via the NixOS configuration and require manual intervention or external management.

## 🌐 Tailscale

### Network DNS Settings

- **Issue**: You cannot configure the global DNS servers for the Tailscale network (the "Tailnet") via NixOS.
- **Action Required**: Nameservers must be configured centrally in the **Tailscale Admin Console** (Web UI) under the DNS tab. If a DNS server (like Blocky) changes IP, it must be updated there.

### ACLs and Tags

- **Issue**: While you can specify tags in the NixOS configuration for a node, the permission to apply those tags must be granted in the Tailscale ACLs.
- **Action Required**: Ensure the ACLs in the Tailscale Admin Console allow the generated auth keys to apply the desired tags.

## 💾 Restic Backups

### Stale Locks

- **Issue**: If a backup job is interrupted or fails to clean up, Restic will leave an exclusive lock on the repository. Subsequent backups will fail with a "repository is already locked" error.
- **Action Required**: You must manually unlock the repository using the Restic CLI:
  ```bash
  sudo restic -r <repository-url> unlock
  ```
  This requires the repository password.
