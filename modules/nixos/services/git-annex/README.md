# Git Annex NixOS Module Guide

This guide documents the server-side `git-annex` configuration using the NixOS module located in `modules/nixos/services/git-annex/default.nix`.

## Overview

The NixOS module lets you declaratively configure `git-annex` repositories, services, clustering, and proxying on a server. Pure helper fragments shared with the home-manager module live in `modules/shared/git-annex/lib.nix`.

## Key Features

- **Declarative Repositories**: Define repositories, paths, and descriptions in Nix.
- **Cluster + Proxy Management**: Initialize a cluster, register nodes, and publish proxy configuration so clients can retrieve content *through* the gateway from nodes they cannot reach directly.
- **Per-remote Policy**: Set `cost`, `trust`, `group`, and `wanted` on each remote declaratively.
- **Hybrid Remotes**: Support for remotes that are both Git remotes (for history) and special remotes (for content), like `rsync.net`.
- **Unlocked Repositories**: Optionally keep annexed files as real, editable files (`git annex adjust --unlock`) instead of symlinks.
- **Automatic Initialization**: Handles `git init`, `git annex init`, and initial commits automatically.
- **Service Management**: Runs `git-annex assistant` as a per-repository systemd service for auto-syncing.

## Configuration Reference

### Enabling the Module

```nix
services.git-annex.enable = true;
services.git-annex.sshKeyFile = config.sops.secrets.git_annex_ssh_key.path;
services.git-annex.gpgKeyFile = config.sops.secrets.git_annex_gpg_key.path;
```

> [!IMPORTANT]
> `sshKeyFile` is installed into the git-annex user's `~/.ssh` at mode 600. In production point it at a sops-managed path (as above) — never a world-readable `/nix/store` path. If omitted, the module generates an ephemeral key on first activation.

### Defining Repositories

Repositories are defined under `services.git-annex.repositories`.

#### Example: Stateless Gateway & Backup

A "gateway" that forwards data to a "backup" and keeps none of its own.

```nix
services.git-annex.repositories = {
  # 1. The gateway (keeps no content of its own)
  gateway = {
    path = "/var/lib/git-annex/gateway";
    description = "gateway-1";
    gateway = true;          # Runs `git annex initcluster`
    assistant = true;        # Runs the assistant to auto-sync
    wanted = "nothing";      # Pure router: store nothing locally

    remotes = [{
      name = "backup";
      url = "/var/lib/git-annex/backup";
      clusterNode = "mycluster"; # Register this remote as a node in the cluster
      group = "backup";
      wanted = "standard";       # Backup should want everything
    }];
  };

  # 2. The local backup (storage)
  backup = {
    path = "/var/lib/git-annex/backup";
    description = "kelpy-backup";
    group = "backup";
    wanted = "standard";
    assistant = true;
  };
};
```

### Module Options

- `enable` (bool): Enable the module.
- `sshKeyFile` (path, optional): Private SSH key for git-annex operations (e.g. from `sops-nix`).
- `gpgKeyFile` (path, optional): GPG key to import for the git-annex user (used by encrypted/pubkey remotes).

### Repository Options

- `path` (path): Absolute path to the repository.
- `description` (str): Description for `git annex init`.
- `gateway` (bool): If true, runs `git annex initcluster`.
- `clusterName` (str, optional): Name of the cluster to initialize when `gateway = true` (default `mycluster`).
- `unlock` (bool): If true, runs `git annex adjust --unlock` so annexed files are real, editable files in the working tree instead of symlinks into `.git/annex/objects`.
- `assistant` (bool): Enables a `git-annex-assistant-<name>` systemd service for this repository.
- `wanted` (str): Preferred content expression — `standard`, `nothing`, `not copies=backup:1`, etc.
- `group` (str): Standard group assignment (e.g. `backup`, `transfer`, `client`).
- `numcopies` (int): Global minimum copies setting.
- `tags` (list of str): Tags automatically applied to new files via a `post-commit` hook (see note below).
- `user` / `ownerGroup` (str): User/group to own the repository (default: `git-annex`).
- `remotes` (list): Remotes to add — see below.

### Remote Options

- `name` (str): Name of the remote.
- `url` (str, optional): Git URL (for history). Required for `git` and hybrid remotes.
- `type` (str): Remote type (default `git`). Use `rsync`, `directory`, `S3`, etc. for special remotes.
- `encryption` (str, optional): Encryption mode (`none`, `shared`, `pubkey`).
- `params` (attrs): Extra `initremote` parameters (e.g. `{ directory = "/path"; }`).
- `expectedUUID` (str, optional): **Safety check.** Fails activation if the remote's actual UUID doesn't match.
- `clusterNode` (str, optional): Registers this remote as a node of the named cluster (`remote.<name>.annex-cluster-node`).
- `proxy` (bool): Configures `remote.<name>.annex-proxy true` and runs `git annex updateproxy`, letting clients reach content through this gateway.
- `cost` (int, optional): Sets `remote.<name>.annex-cost`; lower is preferred when the gateway chooses a node to proxy from.
- `trust` (enum, optional): Trust level — `trusted`, `semitrusted`, `untrusted`, `dead` (maps to `git annex trust`/`semitrust`/`untrust`/`dead`).
- `wanted` (str, optional): Preferred content expression for the remote.
- `group` (str, optional): Standard group to assign to the remote.

> [!NOTE]
> **Auto-tagging fires on explicit commits.** The `tags` post-commit hook runs on a plain `git commit`. The git-annex *assistant* may commit through its own machinery; if you rely on tagging, prefer explicit commits or verify the tag landed.

## Cluster + Proxy Retrieval

The headline declarative flow: a client retrieves content it does not hold locally from a backup node it cannot reach directly, *through* the gateway proxy — with no manual git-annex config.

```nix
services.git-annex.repositories.gateway = {
  path = "/var/lib/git-annex/gateway";
  description = "gateway";
  gateway = true;
  clusterName = "mycluster";
  wanted = "nothing";          # Passthrough proxy: keeps no content
  remotes = [{
    name = "backup";
    url = "git-annex@backup:/var/lib/git-annex/backup";
    clusterNode = "mycluster"; # This remote is a node of the cluster
    proxy = true;              # Publish proxy config (updateproxy)
    trust = "trusted";
  }];
};
```

On activation the gateway runs `initcluster`, sets `annex-cluster-node`/`annex-proxy`, applies `trust`, and then `updateproxy` + `updatecluster` to publish `proxy.log`/`cluster.log` to its git-annex branch. A client that adds the gateway as a remote and fetches its git-annex branch (`git fetch origin && git annex merge`) gains virtual remotes `<gateway>-<cluster>` and `<gateway>-<node>`, and can `git annex get <file> --from <gateway>-mycluster`. The client needs **no** proxy/UUID config of its own.

See `tests/git-annex-cluster.nix` for the full end-to-end proof.

## Advanced Usage

### Hybrid Remotes (e.g. Rsync.net)

A remote that is both a Git remote (history) and a special remote (content):

```nix
remotes = [{
  name = "rsync_net";
  url = "user@host.rsync.net:annex.git"; # Git access (also used as rsyncurl)
  type = "rsync";                        # Special remote type
  encryption = "shared";
  expectedUUID = "...";
}];
```

The module avoids the naming clash by appending `-content` to the special remote internally (e.g. `rsync_net-content`). To keep content only on the encrypted special remote, set `wanted` on each side declaratively:

```nix
# git remote: no content; special remote: standard
{ name = "rsync_net"; url = "..."; wanted = "nothing"; }
# the -content special remote is configured via the same entry's type/encryption
```

### Encrypted Remotes

Set `encryption = "shared"` to encrypt content before it leaves the host. The key is stored in the git repository, so anyone with repo access can decrypt, but the storage provider (who sees only ciphertext) cannot. The `git-annex-assistant` service handles encryption/decryption transparently; the module ensures `gnupg` is on its PATH. For `pubkey` encryption, import the key via `gpgKeyFile`.

### Integration with Services (e.g. Paperless)

Repositories can be owned by other users/services:

```nix
services.git-annex.repositories.paperless = {
  path = config.services.paperless.mediaDir;
  user = "paperless";
  ownerGroup = "paperless";
  tags = [ "paperless" ];            # Auto-tag new files
  wanted = "metadata=tag=paperless"; # Only keep paperless files
};
```

## Troubleshooting

### Service Status

```bash
systemctl status git-annex-assistant-<repo-name>
systemctl status git-annex-init-<repo-name>
```

### UUID Mismatch

A "UUID mismatch" error means a remote's actual UUID doesn't match its `expectedUUID` — a safety feature. Update the config with the correct UUID.
