# Stump Media Server NixOS Module Guide

This guide documents the Stump media server configuration using the NixOS module located in [default.nix](file:///home/inkpotmonkey/code/nixos/modules/nixos/services/stump/default.nix).

## Overview
Stump is a free/open-source comics, manga and digital book server. This module provides a declarative way to deploy and manage a Stump instance on NixOS, including automatic bundling of the web UI.

## Key Features
- **Declarative Configuration**: Define ports, data directories, and user identities in Nix.
- **Pre-built Web UI**: Automatically fetches and bundles the React SPA alongside the server binary.
- **Systemd Hardening**: Robust isolation using `PrivateTmp`, `ProtectSystem`, `NoNewPrivileges`, and restrictive `ReadWritePaths`.
- **Integrated Health Checks**: Includes a multi-node NixOS VM integration test for verification.

## Configuration Reference

### Enabling the Module
Add the following to your NixOS configuration:

```nix
services.stump = {
  enable = true;
  # port = 10801;          # Default TCP port
  # openFirewall = true;   # Open the port in the system firewall
  # dataDir = "/var/lib/stump"; # Storage for database, thumbnails, and config
};
```

### Options Detail

- **`services.stump.port`**: The port Stump listens on. Defaults to `10801`.
- **`services.stump.dataDir`**: Location where Stump stores its SQLite database, user configuration, and image thumbnails. Defaults to `/var/lib/stump`.
- **`services.stump.user` / `group`**: The identity the service runs under. Defaults to `stump`.
- **`services.stump.environmentFile`**: Path to an environment file (e.g., a `sops` secret) containing sensitive variables like `STUMP_OIDC_CLIENT_SECRET`.

## Integration Testing
The module includes a comprehensive NixOS VM integration test that validates service startup, API health, and web UI accessibility.

To run the tests:
```bash
nix build .#checks.x86_64-linux.stump --print-build-logs
```

## Troubleshooting

### Service Status
Check if the Stump server is running correctly:
```bash
systemctl status stump.service
```

### Logs
View the runtime logs to debug library scanning or connection issues:
```bash
journalctl -u stump.service -f
```

### Directory Permissions
Ensure the `dataDir` is correctly owned if you are migrating existing data:
```bash
ls -ld /var/lib/stump
# Should be: drwxr-x--- stump stump
```
