{ pkgs, ... }:

pkgs.testers.nixosTest {
  name = "git-annex-stateless";
  nodes = {
    gateway = { config, pkgs, ... }: {
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
    };

    backup = { config, pkgs, ... }: {
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
    };

    client = { config, pkgs, ... }: {
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
    };
  };

  testScript = ''
    start_all()
    
    # Wait for SSH on all nodes
    gateway.wait_for_unit("sshd")
    backup.wait_for_unit("sshd")
    client.wait_for_unit("sshd")

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
        machine.succeed("mkdir -p /var/lib/git-annex/.ssh && echo 'Host *\n  StrictHostKeyChecking no\n' > /var/lib/git-annex/.ssh/config && chown git-annex:git-annex /var/lib/git-annex/.ssh/config")

    # Create file on client
    client.succeed("sudo -u git-annex bash -c 'cd /var/lib/git-annex/client && echo stateless_test > test.txt'")
    
    # Force sync on client to push to gateway
    client.succeed("sudo -u git-annex /run/current-system/sw/bin/git -C /var/lib/git-annex/client annex sync --content")
    
    # Wait for file to reach Gateway
    gateway.wait_for_file("/var/lib/git-annex/gateway/test.txt")
    
    # Force sync on Gateway to merge synced/master into master and push to backup
    gateway.succeed("sudo -u git-annex /run/current-system/sw/bin/git -C /var/lib/git-annex/gateway annex sync --content")
    
    # Wait for file to reach Backup
    backup.wait_for_file("/var/lib/git-annex/backup/test.txt")

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
  '';
}
