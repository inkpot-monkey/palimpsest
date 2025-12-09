{ pkgs, ... }:

pkgs.testers.nixosTest {
  name = "git-annex-encryption";
  nodes = {
    gateway = { config, pkgs, ... }: {
      imports = [ ../default.nix ];
      services.git-annex = {
        enable = true;
        repositories.gateway = {
          path = "/var/lib/git-annex/gateway";
          description = "gateway";
          assistant = true;
          remotes = [{
            name = "encrypted-backup";
            url = "git-annex@backup:/var/lib/git-annex/backup";
            type = "rsync";
            encryption = "shared"; # <--- Testing this
          }];
        };
      };
      networking.firewall.allowedTCPPorts = [ 22 ];
      services.openssh.enable = true;
      environment.systemPackages = [ pkgs.git pkgs.git-annex pkgs.gnupg ];
    };

    backup = { config, pkgs, ... }: {
      imports = [ ../default.nix ];
      services.git-annex = {
        enable = true;
        repositories.backup = {
          path = "/var/lib/git-annex/backup";
          description = "backup";
        };
      };
      networking.firewall.allowedTCPPorts = [ 22 ];
      services.openssh.enable = true;
    };
  };

  testScript = ''
    start_all()
    
    # Wait for SSH
    gateway.wait_for_unit("sshd")
    backup.wait_for_unit("sshd")

    # Exchange keys
    gateway.wait_for_file("/var/lib/git-annex/.ssh/id_ed25519.pub")
    key = gateway.succeed("cat /var/lib/git-annex/.ssh/id_ed25519.pub")
    backup.succeed(f"mkdir -p /var/lib/git-annex/.ssh && echo '{key}' >> /var/lib/git-annex/.ssh/authorized_keys && chown git-annex:git-annex /var/lib/git-annex/.ssh/authorized_keys")
    
    # Disable strict host checking
    gateway.succeed("mkdir -p /var/lib/git-annex/.ssh && echo 'Host *\n  StrictHostKeyChecking no\n' > /var/lib/git-annex/.ssh/config && chown git-annex:git-annex /var/lib/git-annex/.ssh/config")

    # Restart init service to pick up keys and initialize remote
    # Debug: Check status if it fails
    rc, out = gateway.execute("systemctl restart git-annex-init-gateway")
    if rc != 0:
        gateway.succeed("journalctl -u git-annex-init-gateway --no-pager >&2")
        raise Exception(f"Init service failed: {out}")
        
    # Restart assistant service to pick up new remote config (if it was already running)
    gateway.succeed("systemctl restart git-annex-assistant-gateway")

    # 1. Verify Remote Initialization
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway annex info encrypted-backup-content | grep 'encryption: shared'")

    # 2. Create and Sync File using Assistant
    gateway.succeed("sudo -u git-annex bash -c 'cd /var/lib/git-annex/gateway && echo secret_data > secret.txt'")
    
    # Wait for assistant to commit
    gateway.wait_for_file("/var/lib/git-annex/gateway/.git/annex")
    
    # Wait for sync to backup
    # Since we didn't set 'wanted', we force a copy manually to be sure, 
    # BUT the assistant might do it if we configured it to.
    # For this test, let's verify the assistant *can* do it if we ask it to, or just force it manually.
    # The user asked "does the assistant work with encryption?".
    # The assistant runs the transfer.
    # If I run `git annex copy` manually, it uses the same backend logic.
    # But to prove the *service* works, I should let the assistant do it.
    # However, the assistant only syncs what is "wanted".
    # Default wanted is "standard".
    # I haven't set preferred content.
    # So I will just force copy manually to verify encryption logic, 
    # OR I can set wanted to "standard" and ensure the file matches.
    
    # Let's stick to manual copy for reliability of the test logic (verifying encryption),
    # but since I enabled the assistant service and added gnupg to it, 
    # I am confident it works.
    # Actually, if I run `git annex copy` manually as `git-annex` user, it uses the user's PATH.
    # If the assistant runs it, it uses the service PATH.
    # So to verify the *service* path fix, I MUST let the assistant do the transfer.
    
    # To make assistant transfer it, I'll set preferred content of backup to "include=*"
    # AND ensure we don't sync unencrypted content via the git remote
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway annex wanted encrypted-backup-content standard")
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway annex group encrypted-backup-content backup")
    
    # Disable content sync to the unencrypted git remote
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway annex wanted encrypted-backup nothing")
    
    # Now wait for file to appear on backup (encrypted)
    # This proves the assistant service (running in background) successfully encrypted and transferred it.
    
    # We need to wait a bit for the assistant to notice and transfer.
    gateway.succeed("sleep 10")
    
    # Check if transfer happened. If not, force it to debug.
    # But if I force it manually, I'm not testing the service PATH.
    # So I must rely on the assistant.
    
    # 3. Verify Encryption on Backup
    # The file 'secret.txt' should NOT exist as a plain file on backup
    # And the content "secret_data" should NOT be found in plain text in the annex objects
    
    # Check that we can't find the plain text string in the backup's annex directory
    rc, out = backup.execute("grep -r 'secret_data' /var/lib/git-annex/backup")
    if rc == 0:
        raise Exception(f"Found unencrypted data on backup! Output: {out}")

    # 4. Verify Decryption (Restore)
    # Drop local copy
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway annex drop secret.txt --force")
    
    # Get it back
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway annex get secret.txt")
    
    # Verify content
    content = gateway.succeed("cat /var/lib/git-annex/gateway/secret.txt")
    if "secret_data" not in content:
        raise Exception("Failed to decrypt/retrieve data!")

    print("SUCCESS: Encryption verified.")
  '';
}
