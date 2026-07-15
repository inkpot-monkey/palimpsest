{ pkgs, ... }:

let
  helper = import ./lib.nix { inherit pkgs; };
in
pkgs.testers.nixosTest {
  name = "git-annex-encryption";
  nodes = {
    gateway =
      { pkgs, ... }:
      {
        imports = [ helper.commonNode ];
        services.git-annex.repositories.gateway = {
          path = "/var/lib/git-annex/gateway";
          description = "gateway";
          remotes = [
            {
              name = "encrypted-backup";
              url = "git-annex@backup:/var/lib/git-annex/backup";
              type = "rsync";
              encryption = "shared"; # <-- under test
            }
          ];
        };
        # gnupg must be on the git-annex user's login PATH for manual annex ops.
        environment.systemPackages = [
          pkgs.git
          pkgs.git-annex
          pkgs.gnupg
        ];
      };

    backup =
      { ... }:
      {
        imports = [ helper.commonNode ];
        services.git-annex.repositories.backup = {
          path = "/var/lib/git-annex/backup";
          description = "backup";
        };
      };
  };

  testScript = ''
    start_all()

    gateway.wait_for_unit("git-annex-init-gateway.service")
    backup.wait_for_unit("git-annex-init-backup.service")

    # 1. The encrypted special remote was initialized with shared encryption.
    gateway.succeed(
        "sudo -u git-annex git -C /var/lib/git-annex/gateway annex info encrypted-backup-content | grep 'encryption: shared'"
    )

    # 2. Add a file and copy it to the encrypted remote.
    gateway.succeed("sudo -u git-annex bash -c 'cd /var/lib/git-annex/gateway && echo secret_data > secret.txt'")
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway annex add secret.txt")
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway commit -m 'add secret'")
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway annex copy secret.txt --to encrypted-backup-content")

    # 3. The plaintext must NOT be present anywhere on the backup (it is encrypted).
    rc, out = backup.execute("grep -r 'secret_data' /var/lib/git-annex/backup")
    if rc == 0:
        raise Exception(f"Found unencrypted data on backup! Output: {out}")

    # 4. Decryption/restore: drop the local copy and fetch it back from the remote.
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway annex drop secret.txt --force")
    gateway.succeed("sudo -u git-annex git -C /var/lib/git-annex/gateway annex get secret.txt")
    content = gateway.succeed("cat /var/lib/git-annex/gateway/secret.txt")
    if "secret_data" not in content:
        raise Exception("Failed to decrypt/retrieve data!")

    print("SUCCESS: Encryption verified.")
  '';
}
