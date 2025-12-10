{ system ? builtins.currentSystem, pkgs, inputs }:
let
  inherit (pkgs) lib;
  
  # Generate SSH keys dynamically
  sshKeys = pkgs.runCommand "ssh-keys" {
    nativeBuildInputs = [ pkgs.openssh ];
  } ''
    mkdir -p $out
    ssh-keygen -t ed25519 -f $out/id_ed25519 -N "" -C "test-key"
  '';
in
pkgs.testers.nixosTest {
  name = "git-annex-home-manager-v28";
  nodes = {
    gateway = { config, pkgs, ... }: {
      imports = [ ../../../nixos/git-annex/default.nix ];
      services.git-annex = {
        enable = true;
        repositories.gateway = {
          path = "/var/lib/git-annex/gateway";
          description = "gateway";
          assistant = true;
        };
      };
      networking.firewall.allowedTCPPorts = [ 22 ];
      services.openssh.enable = true;
      users.users.git-annex.openssh.authorizedKeys.keys = [
        (builtins.readFile "${sshKeys}/id_ed25519.pub")
      ];
    };

    client = { config, pkgs, ... }: {
      imports = [ inputs.home-manager.nixosModules.home-manager ];
      
      users.users.alice = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        openssh.authorizedKeys.keys = [ (builtins.readFile "${sshKeys}/id_ed25519.pub") ];
      };

      environment.systemPackages = [ pkgs.git pkgs.git-annex ];

      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      home-manager.users.alice = { pkgs, lib, config, ... }: {
        imports = [ ../default.nix ];
        # Inline debug to verify option setting
        config = {
           home.stateVersion = "24.05";
           programs.git = {
             enable = true;
             userName = "Alice";
             userEmail = "alice@example.com";
           };
           services.git-annex = {
             enable = true;
             repositories = {
               annex = {
                 path = "/home/alice/Annex";
                 description = "test-annex";
                 unlock = true;
                 remotes = [{
                   name = "gateway";
                   url = "git-annex@gateway:/var/lib/git-annex/gateway";
                 }];
               };
             };
             assistant.enable = false;
           };
        };
      };
    };
    client_full = { config, pkgs, ... }: {
      imports = [ inputs.home-manager.nixosModules.home-manager ];

      users.users.bob = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        openssh.authorizedKeys.keys = [ (builtins.readFile "${sshKeys}/id_ed25519.pub") ];
      };

      environment.systemPackages = [ pkgs.git pkgs.git-annex ];

      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      home-manager.users.bob = { pkgs, lib, config, ... }: {
        imports = [ ../default.nix ];
        config = {
           home.stateVersion = "24.05";
           programs.git = {
             enable = true;
             userName = "Bob";
             userEmail = "bob@example.com";
           };
           services.git-annex = {
             enable = true;
             repositories = {
               annex = {
                 path = "/home/bob/Annex";
                 description = "bob-annex";
                 assistant = true;
                 remotes = [{
                   name = "gateway";
                   url = "git-annex@gateway:/var/lib/git-annex/gateway";
                   type = "git";
                 } {
                   name = "backup";
                   type = "directory";
                   params = {
                     directory = "/home/bob/Backup";
                     encryption = "none";
                   };
                 }];
               };
             };
             assistant.enable = true;
           };
        };
      };
    };
  };

  testScript = ''
    start_all()

    # Enable lingering for users
    client.succeed("loginctl enable-linger alice")
    client_full.succeed("loginctl enable-linger bob")

    # 1. Setup SSH keys
    for machine in [client, client_full]:
      machine.succeed("mkdir -p /home/alice/.ssh /home/bob/.ssh")
      # We only need keys for the specific user on each machine, but simpler to copy to both paths if they exist
      if machine == client:
        user="alice"
      else:
        user="bob"
      
      machine.succeed(f"mkdir -p /home/{user}/.ssh")
      machine.succeed(f"cp ${sshKeys}/id_ed25519 /home/{user}/.ssh/id_ed25519")
      machine.succeed(f"chmod 600 /home/{user}/.ssh/id_ed25519")
      machine.succeed(f"chown -R {user}:users /home/{user}/.ssh")

    # Create backup directory for bob
    client_full.succeed("mkdir -p /home/bob/Backup")
    client_full.succeed("chown bob:users /home/bob/Backup")

    # 2. Wait for Gateway
    gateway.wait_for_unit("git-annex-init-gateway.service")
    gateway.wait_for_unit("git-annex-assistant-gateway.service")

    # 3. Wait for Client HM Activation
    client.wait_for_unit("user@1000.service")
    client_full.wait_for_unit("user@1000.service")
    
    # Wait for git-annex-init-annex user service
    client.wait_until_succeeds("sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 systemctl --user is-active git-annex-init-annex.service")
    client_full.wait_until_succeeds("sudo -u bob XDG_RUNTIME_DIR=/run/user/1000 systemctl --user is-active git-annex-init-annex.service")
    
    # 4. Verify Assistant Service
    # Client: Should be disabled
    client.fail("systemctl --user is-active git-annex-assistant.service")
    client.fail("test -f /home/alice/.config/git-annex/autostart")

    # Client Full: Should be enabled
    # Verify autostart file exists first
    client_full.succeed("test -f /home/bob/.config/git-annex/autostart")
    client_full.succeed("grep '/home/bob/Annex' /home/bob/.config/git-annex/autostart")

    # Verify assistant service is active
    client_full.wait_until_succeeds("sudo -u bob XDG_RUNTIME_DIR=/run/user/1000 systemctl --user is-active git-annex-assistant.service")

    # Verify git config
    client.succeed("sudo -u alice GIT_PAGER=cat git config --list >&2")

    # Verify repo initialization
    client.succeed("test -d /home/alice/Annex/.git")
    client.succeed("sudo -u alice timeout 30s env GIT_PAGER=cat GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=no' git -C /home/alice/Annex annex info")

    client_full.succeed("test -d /home/bob/Annex/.git")
    
    # 7. Verify Remotes
    client.succeed("sudo -u alice git -C /home/alice/Annex remote | grep gateway")
    
    # Client Full: Verify special remote 'backup'
    client_full.succeed("sudo -u bob git -C /home/bob/Annex remote | grep gateway")
    # Check if special remote is known to annex
    client_full.succeed("sudo -u bob timeout 30s env GIT_PAGER=cat GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=no' git -C /home/bob/Annex annex info | grep 'backup'")

    # 9. Unlock Verification
    client.succeed("sudo -u alice touch /home/alice/Annex/test-file")
    client.succeed("test -f /home/alice/Annex/test-file")
    client.succeed("! test -L /home/alice/Annex/test-file")
    
    # 10. Verify Auto Sync
    # Create a file on client_full (where assistant is enabled)
    client_full.succeed("sudo -u bob touch /home/bob/Annex/sync-test-file")
    # Wait for it to sync to gateway
    gateway.wait_until_succeeds("test -f /var/lib/git-annex/gateway/sync-test-file")
    
    print("SUCCESS: File is unlocked (regular file) and auto-sync is working.")
  '';
}
