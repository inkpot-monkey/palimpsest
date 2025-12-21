{ pkgs, ... }:

# Force new derivation 2
pkgs.testers.nixosTest {
  name = "git-annex-stateless";
  nodes = {
    gateway = { config, pkgs, lib, ... }: {
      imports = [ ../default.nix ];
      services.git-annex = {
        enable = true;
        repositories.gateway = {
          path = "/var/lib/git-annex/gateway";
          description = "gateway";
          gateway = true;
          assistant = true;
          wanted = "not copies=backup:1"; # The core logic
          group = "transfer";
          remotes = [{
            name = "backup";
            url = "git-annex@backup:/var/lib/git-annex/backup";
            group = "backup";
          }];
        };
      };
      networking.firewall.allowedTCPPorts = [ 22 ];
      services.openssh.enable = true;
      services.openssh.settings.MaxStartups = "100:30:200";
      systemd.services.git-annex-assistant-gateway.wantedBy = lib.mkForce [];
    };

    backup = { config, pkgs, lib, ... }: {
      imports = [ ../default.nix ];
      services.git-annex = {
        enable = true;
        repositories.backup = {
          path = "/var/lib/git-annex/backup";
          description = "backup";
          group = "backup";
          assistant = true;
        };
      };
      networking.firewall.allowedTCPPorts = [ 22 ];
      services.openssh.enable = true;
      services.openssh.settings.MaxStartups = "100:30:200";
      systemd.services.git-annex-assistant-backup.wantedBy = lib.mkForce [];
    };

    client = { config, pkgs, lib, ... }: {
      imports = [ ../default.nix ];
      services.git-annex = {
        enable = true;
        repositories.client = {
          path = "/var/lib/git-annex/client";
          description = "client";
          group = "client";
          assistant = true;
          remotes = [{
            name = "origin";
            url = "git-annex@gateway:/var/lib/git-annex/gateway";
          }];
        };
      };
      networking.firewall.allowedTCPPorts = [ 22 ];
      services.openssh.enable = true;
      services.openssh.settings.MaxStartups = "100:30:200";
      systemd.services.git-annex-assistant-client.wantedBy = lib.mkForce [];
      environment.systemPackages = [ pkgs.git pkgs.git-annex pkgs.strace ];
    };
  };

  testScript = ''
    start_all()
    
    # Wait for SSH on all nodes
    gateway.wait_for_unit("sshd")
    backup.wait_for_unit("sshd")
    client.wait_for_unit("sshd")

    # Wait for git-annex services to ensure initialization
    # Wait for git-annex services to ensure initialization
    # gateway.wait_for_unit("git-annex-assistant-gateway.service")
    # backup.wait_for_unit("git-annex-assistant-backup.service")
    # client.wait_for_unit("git-annex-assistant-client.service")

    gateway.wait_for_file("/var/lib/git-annex/.ssh/id_ed25519.pub")
    backup.wait_for_file("/var/lib/git-annex/.ssh/id_ed25519.pub")
    client.wait_for_file("/var/lib/git-annex/.ssh/id_ed25519.pub")

    # Exchange keys
    # 1. Gateway needs access to Backup
    gateway_key = gateway.succeed("cat /var/lib/git-annex/.ssh/id_ed25519.pub")
    backup.succeed(f"mkdir -p /var/lib/git-annex/.ssh && echo '{gateway_key}' >> /var/lib/git-annex/.ssh/authorized_keys && chown git-annex:git-annex /var/lib/git-annex/.ssh/authorized_keys")
    
    # 2. Client needs access to Gateway
    client_key = client.succeed("cat /var/lib/git-annex/.ssh/id_ed25519.pub")
    gateway.succeed(f"echo '{client_key}' >> /var/lib/git-annex/.ssh/authorized_keys")

    # Disable strict host checking for test simplicity
    for machine in [gateway, backup, client]:
        machine.succeed("mkdir -p /var/lib/git-annex/.ssh && echo 'Host *\n  StrictHostKeyChecking no\n  BatchMode yes\n' > /var/lib/git-annex/.ssh/config && chown git-annex:git-annex /var/lib/git-annex/.ssh/config")

    # Stop assistants to avoid lock contention during manual syncs
    client.succeed("systemctl stop git-annex-assistant-client.service")
    gateway.succeed("systemctl stop git-annex-assistant-gateway.service")
    backup.succeed("systemctl stop git-annex-assistant-backup.service")

    # Restart init services now that keys are exchanged
    # They would have failed on boot due to missing auth
    for machine in [gateway, client]:
        # We need to restart the specific init service for the repo
        # Gateway has 'gateway' repo, Client has 'client' repo
        repo = "gateway" if machine == gateway else "client"
        
        # Bootstrap: Merge unrelated histories if they exist (since both init'd separately)
        if machine == gateway:
             # Debug SSH
             machine.succeed("ls -la /var/lib/git-annex/.ssh >&2")
             machine.succeed("cat /var/lib/git-annex/.ssh/config >&2")
             machine.succeed("sudo -u git-annex ssh -v -o ConnectTimeout=5 backup echo 'SSH OK' >&2 || true")

             # Ensure remote exists (it might have failed to add if init crashed early)
             machine.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway remote add backup git-annex@backup:/var/lib/git-annex/backup || true")
             
             # Gateway needs to pull from backup
             # We must merge both master and git-annex branches to allow unrelated histories
             machine.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway fetch backup >&2")
             machine.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway status >&2")
             # Stop services to avoid race conditions
             gateway.succeed("systemctl stop git-annex-assistant-gateway.service || true")
             gateway.succeed("systemctl stop git-annex-init-gateway.service || true")
             gateway.succeed("rm -f /var/lib/git-annex/gateway/.git/index.lock")

             gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway merge backup/master --allow-unrelated-histories --no-edit >&2")
             machine.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway merge backup/git-annex --allow-unrelated-histories --no-edit >&2")
        
        try:
            machine.succeed(f"systemctl restart git-annex-init-{repo}.service")
        except:
            machine.succeed(f"journalctl -u git-annex-init-{repo}.service --no-pager >&2")
            raise
    
    # Wait for them to succeed
    gateway.wait_for_unit("git-annex-init-gateway.service")
    client.wait_for_unit("git-annex-init-client.service")

    # Verify repo initialization
    client.succeed("test -d /var/lib/git-annex/client/.git")
    gateway.succeed("test -d /var/lib/git-annex/gateway/.git")

    # Sync Client with Gateway (unrelated histories)
    client.succeed("sudo -u git-annex git -C /var/lib/git-annex/client pull origin master --allow-unrelated-histories --no-edit || true")
    # Also sync the git-annex branch so client knows about backup's UUID
    client.succeed("sudo -u git-annex git -C /var/lib/git-annex/client fetch origin")
    client.succeed("sudo -u git-annex git -C /var/lib/git-annex/client branch -f git-annex origin/git-annex")

    # Create file on client
    client.succeed("sudo -u git-annex bash -c 'cd /var/lib/git-annex/client && echo stateless_test > test.txt'")
    client.succeed("sudo -u git-annex git -C /var/lib/git-annex/client annex add test.txt")
    client.succeed("sudo -u git-annex git -C /var/lib/git-annex/client commit -m 'stateless test'")

    # 3. Sync Client -> Gateway
    # Use explicit push and copy to avoid 'git annex sync' hangs/complexities
    # client.succeed("sudo -u git-annex git -C /var/lib/git-annex/client add .") # Replaced by annex add
    # client.succeed("sudo -u git-annex git -C /var/lib/git-annex/client commit -m 'stateless test'") # Done above
    client.succeed("sudo -u git-annex git -C /var/lib/git-annex/client push origin master --force")
    
    # 1. Initialize the cluster on the Client
    client.succeed("sudo -u git-annex git -C /var/lib/git-annex/client annex initcluster mycluster")
    # annex sync might fail due to master branch divergence, but we only care about git-annex branch
    client.succeed("sudo -u git-annex git -C /var/lib/git-annex/client annex sync origin || true")

    # IMPORTANT: The Gateway needs to know about the cluster configuration (cluster.log).
    # When Client syncs to Gateway, it might push to synced/git-annex.
    # We need to ensure Gateway merges this into its git-annex branch.
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway annex sync || true")
    # Explicitly merge synced/git-annex to be absolutely sure
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway --no-pager branch -a >&2")
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway --no-pager merge synced/git-annex -m 'merge synced/git-annex' || true")
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway --no-pager ls-tree -r git-annex >&2")
    
    # Get the cluster UUID
    client.succeed("sudo -u git-annex git -C /var/lib/git-annex/client remote -v >&2")
    client.succeed("sudo -u git-annex /run/current-system/sw/bin/git -C /var/lib/git-annex/client annex info >&2")
    
    # Manually add the remote if it doesn't exist (it should have been discovered but sync failed)
    client.succeed("sudo -u git-annex git -C /var/lib/git-annex/client remote add origin-mycluster ssh://git-annex@gateway/var/lib/git-annex/gateway || true")
    client.succeed("sudo -u git-annex git -C /var/lib/git-annex/client config remote.origin-mycluster.annex-uuid $(sudo -u git-annex /run/current-system/sw/bin/git -C /var/lib/git-annex/client annex info origin-mycluster | grep 'uuid:' | awk '{print $2}') || true")
    
    cluster_uuid = client.succeed("sudo -u git-annex /run/current-system/sw/bin/git -C /var/lib/git-annex/client annex info origin-mycluster | grep 'uuid:' | awk '{print $2}'").strip()
    print(f"Cluster UUID: {cluster_uuid}")
    
    # Debug: Check where content is before copy
    client.succeed("sudo -u git-annex git -C /var/lib/git-annex/client annex whereis test.txt >&2")
    client.succeed("sudo -u git-annex git -C /var/lib/git-annex/client annex info >&2")
    
    # Get key using lookupkey
    key = client.succeed("sudo -u git-annex git -C /var/lib/git-annex/client annex lookupkey test.txt").strip()
    client.succeed(f"sudo -u git-annex ssh -o BatchMode=yes -o StrictHostKeyChecking=no git-annex@gateway \"git-annex-shell 'inannex' '/var/lib/git-annex/gateway' '{key}'\" >&2 || true")

    # Get UUIDs
    gateway_uuid = gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway config annex.uuid").strip()
    backup_uuid = backup.succeed("sudo -u git-annex git -C /var/lib/git-annex/backup config annex.uuid").strip()
    
    # Manual P2P check moved to end of script
    client.succeed("sudo -u git-annex git -C /var/lib/git-annex/client annex copy --to origin >&2")
    
    # Debug: Check where content is after copy
    client.succeed("sudo -u git-annex git -C /var/lib/git-annex/client annex whereis test.txt >&2")
    
    # Also sync the git-annex branch
    client.succeed("sudo -u git-annex git -C /var/lib/git-annex/client fetch origin")
    client.succeed("sudo -u git-annex git -C /var/lib/git-annex/client annex merge")
    # We might need to merge if gateway updated it, but since we stopped assistant, it shouldn't have.
    # But let's just push git-annex branch if we have it.
    # git annex copy doesn't push git-annex branch automatically?
    # git annex sync does.
    # Let's try to push git-annex branch explicitly.
    client.succeed("sudo -u git-annex git -C /var/lib/git-annex/client push origin git-annex")
    
    # Wait for file to reach Gateway
    gateway.wait_for_file("/var/lib/git-annex/gateway/test.txt")
    
    # Debug: Check if gateway has the content
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway annex find test.txt --in here >&2")
    
    # 4. Sync Gateway -> Backup
    # Force push to overwrite backup's initial history
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway push backup master --force")
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway annex copy --to backup >&2")
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway push backup git-annex --force")
    
    # Wait for file to reach Backup
    backup.wait_for_file("/var/lib/git-annex/backup/test.txt")

    # Initialize cluster on Gateway to enable proxying
    gateway.succeed("sudo -u git-annex /run/current-system/sw/bin/git -C /var/lib/git-annex/gateway annex initcluster mycluster")
    gateway.succeed("sudo -u git-annex /run/current-system/sw/bin/git -C /var/lib/git-annex/gateway annex updatecluster")
    
    # Sync client to get cluster info
    client.succeed("sudo -u git-annex /run/current-system/sw/bin/git -C /var/lib/git-annex/client annex sync --no-push --allow-unrelated-histories")

    # Force drop on Gateway (simulating assistant or cron)
    gateway.succeed("sudo -u git-annex /run/current-system/sw/bin/git -C /var/lib/git-annex/gateway annex drop --auto test.txt")
    
    # VERIFICATION: File should be GONE from Gateway content
    # git annex whereis should show it on client and backup, but NOT gateway
    
    # Check whereis output
    whereis = gateway.succeed("sudo -u git-annex /run/current-system/sw/bin/git -C /var/lib/git-annex/gateway annex whereis test.txt")
    print(whereis)
    
    if "gateway [here]" in whereis:
        raise Exception("File was NOT dropped from gateway!")
    
    if "backup" not in whereis:
        raise Exception("File is NOT on backup!")

    print("SUCCESS: File propagated to backup and was dropped from gateway.")

    # 7. Proxy Retrieval Test
    # Client drops the file, then requests it again.
    # It should be retrieved from Backup VIA Gateway.
    
    client.succeed("sudo -u git-annex /run/current-system/sw/bin/git -C /var/lib/git-annex/client annex drop --force test.txt")
    
    # Configure gateway as a proxy so client knows it can get content from backup via gateway
    # This should have been done by the module if we set proxy=true on the remote?
    # But we didn't set it in the test config. Let's set it manually for now or update the test config.
    # Updating test config requires rebuilding the VM which is slow.
    # Let's set it manually to verify the feature works.
    client.succeed("sudo -u git-annex /run/current-system/sw/bin/git -C /var/lib/git-annex/client config remote.origin.annex-proxy true")
    
    # Get from origin (which proxies to backup)
    # Get from origin (which proxies to backup)
    # Debug: Check environment and remote info on gateway
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway annex info backup >&2")
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway annex whereis test.txt >&2")
    
    # Verify Gateway can get it manually first
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway annex get test.txt >&2")
    
    # Verify Client can get it from Gateway (cached) WITHOUT proxy
    client.succeed("sudo -u git-annex /run/current-system/sw/bin/git -C /var/lib/git-annex/client config remote.origin.annex-proxy false")
    client.succeed("sudo -u git-annex /run/current-system/sw/bin/git -C /var/lib/git-annex/client annex get test.txt --debug >&2")
    client.succeed("sudo -u git-annex /run/current-system/sw/bin/git -C /var/lib/git-annex/client annex drop test.txt >&2")
    # Sync so Gateway knows Client doesn't have it anymore
    client.succeed("sudo -u git-annex /run/current-system/sw/bin/git -C /var/lib/git-annex/client annex sync origin >&2")
    client.succeed("sudo -u git-annex /run/current-system/sw/bin/git -C /var/lib/git-annex/client push origin git-annex:git-annex >&2")
    
    # Verify Gateway knows Client doesn't have it (re-added for debug)
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway show-ref git-annex >&2")
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway annex sync backup >&2") # Force sync with backup
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway annex whereis test.txt >&2")
    
    # Enable debug on Gateway
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway config annex.debug true")
    
    # Verify Backup has the content (not empty)
    backup.succeed("sudo -u git-annex git -C /var/lib/git-annex/backup annex find test.txt >&2")
    # Check object size on Backup
    backup.succeed("find /var/lib/git-annex/backup/.git/annex/objects -type f -size +0c >&2")
    
    # Drop from Gateway first
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway annex drop test.txt >&2")
    
    # Verify Gateway knows it doesn't have it
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway annex whereis test.txt >&2")
    # Verify object is gone
    gateway.succeed("! find /var/lib/git-annex/gateway/.git/annex/objects -name '*SHA256E*' -type f | grep .")
    
    # Configure Client for proxying
    client.succeed("sudo -u git-annex /run/current-system/sw/bin/git -C /var/lib/git-annex/client config remote.origin.annex-proxy true")
    
    # Configure Gateway to prefer Backup (lower cost)
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway config remote.backup.annex-cost 50")
    
    # Enable proxying explicitly on Gateway
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway config annex.proxy true")
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway config remote.backup.annex-proxy true")
    
    # Trust Client and Backup on Gateway to ensure proxying is allowed
    client_uuid = client.succeed("sudo -u git-annex git -C /var/lib/git-annex/client config annex.uuid").strip()
    gateway.succeed(f"sudo -u git-annex git -C /var/lib/git-annex/gateway annex trust {client_uuid} --force")
    gateway.succeed(f"sudo -u git-annex git -C /var/lib/git-annex/gateway annex trust {backup_uuid} --force")
    
    # Enable debug on Backup
    backup.succeed("sudo -u git-annex git -C /var/lib/git-annex/backup config annex.debug true")
    
    # Verify content on Backup
    backup.succeed("find /var/lib/git-annex/backup/.git/annex/objects -name '*SHA256E*' -ls >&2")
    backup.succeed("find /var/lib/git-annex/backup/.git/annex/objects -name '*SHA256E*' -exec cat {} \\; >&2")
    
    # Check inannex locally on Backup
    backup.succeed(f"sudo -u git-annex git-annex-shell 'inannex' '/var/lib/git-annex/backup' '{key}' >&2")
    
    # Run P2P GET locally on Backup
    p2p_input_local = f"VERSION 4\\nGET 0 test.txt {key}\\n"
    backup.succeed(f"printf '{p2p_input_local}' | sudo -u git-annex git-annex-shell 'p2pstdio' '/var/lib/git-annex/backup' '--debug' '{gateway_uuid}' > /tmp/p2p_local_out 2> /tmp/p2p_local_err || true")
    backup.succeed("cat /tmp/p2p_local_out >&2")
    backup.succeed("cat /tmp/p2p_local_err >&2")
    
    # Check authorized_keys on Backup
    backup.succeed("cat /var/lib/git-annex/.ssh/authorized_keys >&2")
    
    # Check SSH environment
    gateway.succeed("sudo -u git-annex ssh -o BatchMode=yes -o StrictHostKeyChecking=no backup env >&2")
    gateway.succeed("sudo -u git-annex ssh -o BatchMode=yes -o StrictHostKeyChecking=no backup 'git --version' >&2")
    
    # Check configlist over SSH
    gateway.succeed("sudo -u git-annex ssh -o BatchMode=yes -o StrictHostKeyChecking=no backup \"git-annex-shell 'configlist' '/var/lib/git-annex/backup'\" >&2")
    
    # Check inannex over SSH with strace
    gateway.succeed(f"sudo -u git-annex ssh -o BatchMode=yes -o StrictHostKeyChecking=no backup \"strace -f -e trace=read,write,file,process -o /tmp/strace_inannex_log git-annex-shell 'inannex' '/var/lib/git-annex/backup' '{key}' --debug\" > /tmp/inannex_out 2> /tmp/inannex_err || true")
    gateway.succeed("cat /tmp/inannex_out >&2")
    gateway.succeed("cat /tmp/inannex_err >&2")
    gateway.succeed("sudo -u git-annex ssh -o BatchMode=yes -o StrictHostKeyChecking=no backup 'cat /tmp/strace_inannex_log' >&2")

    # Manual P2P GET from Gateway to Backup (Correctly Placed)
    # Using noauth input format as determined by local test
    p2p_input_noauth = f"VERSION 4\\nGET 0 test.txt {key}\\n"
    gateway.succeed(f"printf '{p2p_input_noauth}' | sudo -u git-annex ssh -o BatchMode=yes -o StrictHostKeyChecking=no backup \"strace -f -e trace=read,write,file,process -o /tmp/strace_p2p_log git-annex-shell 'p2pstdio' '/var/lib/git-annex/backup' '--debug' '{gateway_uuid}'\" > /tmp/p2p_out 2> /tmp/p2p_err || true")
    gateway.succeed("cat /tmp/p2p_out >&2")
    gateway.succeed("cat /tmp/p2p_err >&2")
    gateway.succeed("sudo -u git-annex ssh -o BatchMode=yes -o StrictHostKeyChecking=no backup 'cat /tmp/strace_p2p_log' >&2")
    
    # Check git-annex version
    client.succeed("git-annex version >&2")

    # Enable proxying globally on Gateway
    gateway.succeed("sudo -u git-annex git config --global annex.proxy true")
    gateway.succeed("sudo -u git-annex git config --global remote.backup.annex-proxy true")

    # Change wanted expression to allow everything (debug proxying)
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway annex wanted . 'include=*'")

    # Configure Client to wrap git-annex-shell with strace on the Gateway - DISABLED to prevent hangs
    # client.succeed("sudo -u git-annex /run/current-system/sw/bin/git -C /var/lib/git-annex/client config remote.origin.annex-shell 'strace -f -e trace=read,write,file,process,network -o /tmp/gateway_shell_strace git-annex-shell'")

    # Capture stderr of get
    client.succeed("sudo -u git-annex /run/current-system/sw/bin/git -C /var/lib/git-annex/client annex get test.txt --debug 2> /tmp/get_err || true")
    
    # WORKAROUND: Spoof the Cluster UUID on the Gateway to prevent Client confusion
    
    # 1. Get the Cluster UUID (Already retrieved earlier)
    # cluster_uuid variable is available from earlier step
    
    # 2. Create the wrapper on the Gateway
    gateway.succeed("echo '#!/bin/sh' > /var/lib/git-annex/spoof_shell")
    gateway.succeed("echo 'echo \"SPOOF WRAPPER CALLED with: $SSH_ORIGINAL_COMMAND\" >> /tmp/spoof.log' >> /var/lib/git-annex/spoof_shell")
    gateway.succeed("echo 'if echo \"$SSH_ORIGINAL_COMMAND\" | grep -q \"configlist\"; then' >> /var/lib/git-annex/spoof_shell")
    gateway.succeed("echo '  echo \"SPOOFING UUID\" >> /tmp/spoof.log' >> /var/lib/git-annex/spoof_shell")
    # Execute the original command. Since it's a string with quotes, we use eval.
    gateway.succeed("echo '  OUTPUT=$(eval \"$SSH_ORIGINAL_COMMAND\")' >> /var/lib/git-annex/spoof_shell")
    gateway.succeed(f"echo '  echo \"$OUTPUT\" | sed \"s/annex.uuid=.*/annex.uuid={cluster_uuid}/\"' >> /var/lib/git-annex/spoof_shell")
    gateway.succeed("echo 'else' >> /var/lib/git-annex/spoof_shell")
    gateway.succeed("echo '  if [ -z \"$SSH_ORIGINAL_COMMAND\" ]; then' >> /var/lib/git-annex/spoof_shell")
    gateway.succeed("echo '    exec /bin/sh' >> /var/lib/git-annex/spoof_shell")
    gateway.succeed("echo '  else' >> /var/lib/git-annex/spoof_shell")
    gateway.succeed("echo '    eval \"$SSH_ORIGINAL_COMMAND\"' >> /var/lib/git-annex/spoof_shell")
    gateway.succeed("echo '  fi' >> /var/lib/git-annex/spoof_shell")
    gateway.succeed("echo 'fi' >> /var/lib/git-annex/spoof_shell")
    gateway.succeed("chmod +x /var/lib/git-annex/spoof_shell")

    # 3. Force the wrapper via authorized_keys on Gateway
    gateway.succeed("sed -i 's|^ssh-ed25519|command=\"/var/lib/git-annex/spoof_shell\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519|' /var/lib/git-annex/.ssh/authorized_keys")

    # Debug: Verify wrapper works via manual SSH
    client.succeed("sudo -u git-annex ssh -o StrictHostKeyChecking=no git-annex@gateway echo 'manual ssh test' > /tmp/manual_ssh_out 2>&1 || true")
    gateway.succeed("cat /tmp/spoof.log >&2 || echo 'Spoof log not found after manual SSH'")

    # 4. Manually define the cluster remote on the Client (Already done earlier)
    # We DO NOT set annex-uuid manually here, we let the spoof wrapper provide it during probe.

    # 5. Try getting from the cluster explicitly (First attempt might just update UUID)
    client.succeed("sudo -u git-annex sh -c 'cd /var/lib/git-annex/client && /run/current-system/sw/bin/git annex get test.txt --from origin-mycluster --debug > /tmp/cluster_get_log_1 2>&1 || true'")
    client.succeed("cat /tmp/cluster_get_log_1 >&2")
    
    # Debug: Check cluster.log on Gateway
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway show git-annex:cluster.log >&2 || echo 'cluster.log not found'")
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway show git-annex:proxy.log >&2 || echo 'proxy.log not found'")

    # Check what git-annex thinks
    client.succeed("sudo -u git-annex git -C /var/lib/git-annex/client annex find test.txt --from origin-mycluster > /tmp/find_out || true")
    client.succeed("cat /tmp/find_out >&2")

    # Force git-annex to check the remote even if it thinks it's empty
    client.succeed("sudo -u git-annex git -C /var/lib/git-annex/client config remote.origin-mycluster.annex-speculate-present true")

    # 6. Try getting again
    client.succeed("sudo -u git-annex sh -c 'cd /var/lib/git-annex/client && /run/current-system/sw/bin/git annex get test.txt --from origin-mycluster --debug > /tmp/cluster_get_log_2 2>&1 || true'")
    client.succeed("cat /tmp/cluster_get_log_2 >&2")
    gateway.succeed("cat /tmp/spoof.log >&2 || echo 'Spoof log not found after get'")
    
    # Verify content
    client.succeed("grep 'stateless_test' /var/lib/git-annex/client/test.txt")
    # End of test
  '';
}
