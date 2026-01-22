# JMAP Matrix Bridge Module

This NixOS module deploys the `jmap-matrix-bridge` service, managing the process, environment, and persistence.

## Options

| Option | Type | Default | Description |
|Service | --- | --- | --- |
| `services.jmap-bridge.enable` | bool | `false` | Enable the JMAP Bridge service. |
| `services.jmap-bridge.jmapUrl` | str | `"http://127.0.0.1:8080"` | URL of the JMAP server. |
| `services.jmap-bridge.jmapUsername` | str | - | Username for JMAP authentication. |
| `services.jmap-bridge.jmapToken` | str | `""` | **Optional**. JMAP Password. If set, it is stored in the world-readable Nix store. Prefer using `sops` secrets via `environmentFile`. |
| `services.jmap-bridge.matrixUrl` | str | `"http://127.0.0.1:6167"` | URL of the Matrix Homeserver (Client-Server API). |
| `services.jmap-bridge.databaseUrl` | str | `"sqlite:/var/lib/jmap-bridge/bridge.db"` | Path to the SQLite database. |
| `services.jmap-bridge.environmentFile` | path | `null` | Path to a file containing environment variables (e.g., from `sops-nix`). Used for secure secret injection (`JMAP_TOKEN`, `MATRIX_AS_TOKEN`). |

## Example Usage

```nix
{ config, pkgs, ... }:
{
  services.jmap-bridge = {
    enable = true;
    jmapUsername = "user@example.com";
    jmapUrl = "https://mail.example.com";
    matrixUrl = "http://localhost:6167";
    
    # Load secrets (JMAP_TOKEN, MATRIX_AS_TOKEN) from sops
    environmentFile = config.sops.secrets.jmap_bridge_env.path;
  };
}
```

## Secrets Handling

This module allows secure injection of sensitive tokens via `environmentFile`. 

1.  **MATRIX_AS_TOKEN**: Required. Sourced from the `as_token` in your generated `registration.yaml`.
2.  **JMAP_TOKEN**: Required. The password/token for the JMAP user.

Define these in your `sops` secrets file:
```env
MATRIX_AS_TOKEN=your_token_here
JMAP_TOKEN=your_password_here
```

## Persistance

The service runs with `DynamicUser = true` but persists data in `/var/lib/jmap-bridge/` (managed via `StateDirectory`).
The SQLite database `bridge.db` stores sync mappings and is critical for idempotency.
