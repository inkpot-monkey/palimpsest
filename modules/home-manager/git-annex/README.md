# Git Annex Home Manager Module Guide

This guide documents the client-side `git-annex` configuration using the Home Manager module located in `modules/home-manager/git-annex.nix`.

## Overview
The Home Manager module allows you to configure `git-annex` on your personal machines (e.g., laptops, workstations). It focuses on setting up repositories that sync with a central gateway.

## Key Features
- **Declarative Repositories**: Define repositories and their remotes in your home configuration.
- **Auto-Unlock**: Automatically unlock files for easy usage (no need to `git annex get`).
- **Assistant Service**: Runs the assistant as a user service to auto-sync changes.
- **Proxy Configuration**: Easily configure clients to route traffic through a gateway to hidden backup nodes.
- **Failsafes**: Pin remote UUIDs to prevent connecting to the wrong server.

## Configuration Reference

### Enabling the Module
```nix
imports = [ ./modules/home-manager/git-annex.nix ];
programs.git-annex.enable = true;
programs.git-annex.assistant.enable = true;
```

### Defining Repositories
Repositories are defined under `programs.git-annex.repositories`.

#### Example: Client Syncing to Gateway
This setup configures a repository at `~/Annex` that syncs to a gateway server (`kelpy`).

```nix
services.git-annex = {
  enable = true;
  repositories = {
    annex = {
      path = "/home/user/Annex";
      description = "my-annex";
      unlock = true; # Default is false
      remotes = [
        {
          name = "kelpy";
          url = "git-annex@kelpy:~/Annex";
        }
      ];
    };
  };
  # The assistant service is enabled by default if repositories have assistant=true (default false)
  # or you can enable it globally:
  assistant.enable = true;
};
```

### Options Detail

#### Repository Options
*   `path` (path): Absolute path to the repository.
*   `description` (str): Description for `git annex init`.
*   `unlock` (bool): If true, runs `git annex adjust --unlock` after initialization. This makes files appear as normal files (not symlinks) and is recommended for general use.
*   `assistant` (bool): If true, adds this repository to the assistant's autostart list.
*   `wanted` (str): Preferred content expression (e.g., 'standard').
*   `group` (str): Standard group to assign (e.g., 'backup').
*   `numcopies` (int): Global numcopies setting.
*   `remotes` (list): List of remotes to add.

#### Remote Options
*   `name` (str): Name of the remote.
*   `url` (str): Git URL (optional for special remotes).
*   `type` (str): Type of remote (default "git"). Use "rsync", "directory", "S3", etc. for special remotes.
*   `encryption` (str): Encryption setting for special remotes (e.g., "none", "shared", "pubkey").
*   `params` (attrs): Additional parameters for special remotes (e.g., `{ directory = "/path"; }`).
*   `proxy` (bool): If true, configures `remote.<name>.annex-proxy` to true. This is essential for cluster gateways.
*   `expectedUUID` (str): Fails activation if the remote's UUID doesn't match.
*   `wanted` (str): Preferred content expression for the remote.
*   `group` (str): Standard group to assign to the remote.
*   `clusterNode` (str): Configures `remote.<name>.annex-cluster-node`.

## SSH Configuration & Automation

For fully automated background syncing with the Assistant, it is highly recommended to use a **passwordless SSH key** dedicated to the automation, separate from your interactive user key.

### The "Two-Key" Strategy
1.  **Main Key** (`id_ed25519`): Password-protected. Used for interactive SSH sessions. Secure.
2.  **Bot Key** (`id_annex_autostart`): **Passwordless**. Used *only* by the background `git-annex assistant`.

### Setup Steps

1.  **Generate the Bot Key** (on client):
    ```bash
    ssh-keygen -t ed25519 -f ~/.ssh/id_annex_autostart -N "" -C "git-annex-automation"
    ```

2.  **Configure SSH** (`~/.ssh/config`):
    Tell SSH to offer the bot key when connecting to your server (e.g., `kelpy`).
    ```ssh
    Host kelpy
      # Try the bot key first (for automation)
      IdentityFile ~/.ssh/id_annex_autostart
      # Fallback to your main key (for interactive use)
      IdentityFile ~/.ssh/id_ed25519
    ```

3.  **Authorize the Key (Server Side)**:
    *   Add `id_annex_autostart.pub` to the **git-annex user's** `authorized_keys` (e.g., `git-annex@kelpy`).
    *   **DO NOT** add this key to your personal user's `authorized_keys` (e.g., `inkpotmonkey@kelpy`).

This ensures that if the passwordless key is compromised, it can only access the git-annex repository, not your full user shell.

### The "Single Key" Strategy (Simple but Insecure)
If you are comfortable with the security implications, you can use a single, passwordless SSH key for everything.

1.  **Generate Key**: `ssh-keygen -t ed25519 -N ""` (empty passphrase).
2.  **Authorize**: Add the public key to `authorized_keys` on the server.
3.  **Result**: Both interactive logins and the background assistant will work immediately without extra configuration.
    *   **Risk**: If your private key is stolen, the attacker gains full shell access to your server.

### The "Single Key" Strategy (Advanced)
If you prefer to use a single, password-protected SSH key for both interactive sessions and the assistant:

1.  **Requirement**: You must use an SSH agent (e.g., `ssh-agent`, `gpg-agent`, `keychain`).
2.  **Challenge**: Systemd user services do not automatically inherit environment variables (like `SSH_AUTH_SOCK`) from your login shell.
3.  **Solution**: You must ensure `SSH_AUTH_SOCK` is imported into the systemd user environment.

Add this to your shell initialization (e.g., `.bashrc`, `.zshrc`) or use a tool like `keychain` with systemd integration:

```bash
# Example: Import SSH_AUTH_SOCK to systemd user session
if [ -n "$SSH_AUTH_SOCK" ]; then
    systemctl --user import-environment SSH_AUTH_SOCK
fi
```

**Note**: If the agent is not running or the key is not added (`ssh-add`), the background assistant will fail to sync.

## Workflow

### 1. Deployment Order
Because the Client depends on the Server's identity (UUID), you must deploy the Server first.

1.  **Deploy Server**: `nixos-rebuild switch ...` on the gateway.
2.  **Get UUID**: Run `git annex info` on the gateway to get its UUID.
3.  **Update Client Config**: Add the UUID to `expectedUUID` in your Home Manager config.
4.  **Deploy Client**: `home-manager switch ...` (or `nixos-rebuild` if using HM module in NixOS).

### 2. Verification
After deployment, you can verify the connection:

```bash
cd ~/Annex
git annex info
```
You should see the gateway listed as a remote.

To check if the cluster is working (i.e., if you can see the backup node):
```bash
git annex info kelpy
```
This should list the cluster nodes, including the backup.

### 3. Troubleshooting
*   **"UUID mismatch"**: The server was reset. Get the new UUID and update your config.
*   **"Not configured to proxy"**: Ensure `proxy = true` is set for the gateway remote.
*   **Sync not happening**: Check the assistant service:
    ```bash
    systemctl --user status git-annex-assistant
    ```
