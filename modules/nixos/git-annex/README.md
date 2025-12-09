# Git Annex NixOS Module Guide

This guide documents the server-side `git-annex` configuration using the NixOS module located in `modules/nixos/git-annex.nix`.

## Overview
The NixOS module allows you to declaratively configure `git-annex` repositories, services, and clustering on your server.

## Key Features
- **Declarative Repositories**: Define repositories, paths, and descriptions in Nix.
- **Cluster Management**: Automatically initialize and update `git-annex` clusters.
- **Stateless Gateway**: Configure a gateway node that receives files but drops them after forwarding to a backup.
- **Hybrid Remotes**: Support for remotes that are both Git remotes (for history) and Special remotes (for content), like `rsync.net`.
- **Automatic Initialization**: Handles `git init`, `git annex init`, and initial commits automatically.
- **Service Management**: Runs `git-annex assistant` as a systemd service for auto-syncing.

## Configuration Reference

### Enabling the Module
```nix
imports = [ ./modules/nixos/git-annex.nix ];
services.git-annex.enable = true;
```

### Defining Repositories
Repositories are defined under `services.git-annex.repositories`.

#### Example: Stateless Gateway & Backup
This setup configures a "Gateway" that forwards data to a "Backup" and then drops its own copy.

```nix
services.git-annex.repositories = {
  # 1. The Gateway (Stateless)
  gateway = {
    path = "/var/lib/git-annex/gateway";
    description = "gateway-1";
    gateway = true;          # Initializes cluster 'mycluster'
    assistant = true;        # Runs the assistant to auto-sync
    
    # Stateless Policy:
    # "Don't want this file if 1 copy exists in the 'backup' group"
    wanted = "not copies=backup:1"; 
    
    group = "transfer";      # Transfer group: holds files temporarily
    numcopies = 2;           # Enforce 2 copies globally (e.g. Client + Backup)
    
    # Define the backup remote declaratively
    remotes = [{
      name = "backup";
      url = "/var/lib/git-annex/backup";
      clusterNode = "mycluster"; # Registers this remote as a node in the cluster
      expectedUUID = "1bbbb83d-2136-4a5a-8b32-1d8703fa7639"; # <--- MANDATORY: Verifies remote identity
      group = "backup";        # Assign remote to 'backup' group
      wanted = "standard";     # Backup should want everything
    }];
  };

  # 2. The Local Backup (Storage)
  backup = {
    path = "/var/lib/git-annex/backup";
    description = "kelpy-backup";
    group = "backup";
    wanted = "standard";
    assistant = true;
  };
};
```

### Options Detail

#### Repository Options
*   `path` (path): Absolute path to the repository.
*   `description` (str): Description for `git annex init`.
*   `uuid` (str, optional): The UUID of this repository. Useful for referencing it from other configs.
*   `gateway` (bool): If true, runs `git annex initcluster`.
*   `assistant` (bool): Enables the `git-annex-assistant` systemd service.
*   `wanted` (str): Preferred content expression.
    *   `standard`: Default behavior based on group.
    *   `nothing`: Store nothing (pure router).
    *   `not copies=backup:1`: Store nothing *if* a backup exists.
*   `group` (str): Standard group assignment (e.g., `backup`, `transfer`, `client`).
*   `numcopies` (int): Global minimum copies setting.
*   `user` / `ownerGroup` (str): User/Group to own the repository (default: `git-annex`).
*   `tags` (list): List of tags to automatically apply to new files.

#### Remote Options
*   `name` (str): Name of the remote.
*   `url` (str): Git URL (for history).
*   `type` (str): Special remote type (e.g., `rsync`, `S3`). Default `git`.
*   `encryption` (str): Encryption mode (e.g., `none`, `shared`, `pubkey`).
*   `expectedUUID` (str): **Critical**. Fails activation if the remote's UUID doesn't match.
*   `clusterNode` (str): If set, registers this remote as a node in the specified cluster.

## Advanced Usage

### Hybrid Remotes (e.g., Rsync.net)
You can define a remote that acts as both a Git remote (for syncing git history) and a Special remote (for storing file content).

```nix
remotes = [{
  name = "rsync_net";
  url = "user@host.rsync.net:annex.git"; # Git access (also used as rsyncurl)
  type = "rsync";                        # Special remote type
  encryption = "shared";
  expectedUUID = "...";
}];
```
**Note**: The module automatically handles the naming conflict by appending `-content` to the special remote name internally (e.g., `rsync_net-content`).

> [!IMPORTANT]
> **Hybrid Remotes & Encryption**: If you use a hybrid remote with encryption, you must ensure the Assistant prefers the encrypted special remote over the unencrypted Git remote for content.
>
> ```bash
> # On the server (or via declarative 'wanted' if supported):
> git annex wanted rsync_net nothing          # Disable content on unencrypted git remote
> git annex wanted rsync_net-content standard # Enable content on encrypted special remote
> ```

### Encrypted Remotes
To encrypt data before sending it to a remote (e.g., an untrusted backup), set `encryption = "shared"`.

```nix
remotes = [{
  name = "encrypted-backup";
  url = "git-annex@backup:/var/lib/git-annex/backup";
  type = "rsync";
  encryption = "shared"; # Encrypts content with a shared key stored in the git repo
}];
```

*   **Shared Encryption**: The key is stored in the git repository itself. This means anyone with access to the git repository can decrypt the content, but the remote storage provider (who only sees the encrypted files) cannot.
*   **Assistant Support**: The `git-annex-assistant` service automatically handles encryption and decryption transparently. The module ensures `gnupg` is available to the service.

### Integration with Services (e.g., Paperless)
You can create repositories owned by other users/services.

```nix
services.git-annex.repositories.paperless = {
  path = config.services.paperless.mediaDir;
  user = "paperless";
  ownerGroup = "paperless";
  tags = [ "paperless" ]; # Auto-tag new files
  wanted = "metadata=tag=paperless"; # Only keep paperless files
  # ...
};
```

## Troubleshooting

### Service Status
Check the status of the assistant service:
```bash
systemctl status git-annex-assistant-<repo-name>
```

### Initialization Logs
Check the initialization service logs if a repo isn't created:
```bash
systemctl status git-annex-init-<repo-name>
```

### UUID Mismatch
If you see "UUID mismatch" errors in the logs, it means the remote's actual UUID doesn't match `expectedUUID`. This is a safety feature. Update your configuration with the correct UUID.
