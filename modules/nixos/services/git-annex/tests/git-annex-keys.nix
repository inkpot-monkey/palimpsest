{ pkgs, ... }:

# Exercises the sshKeyFile/gpgKeyFile install paths (the production "keys come
# from a sops secret" pattern, here fed from store paths). Single node, no
# remotes: just proves the module installs the SSH private key with the right
# owner/mode and imports the GPG key for the git-annex user.
let
  sshKey =
    pkgs.runCommand "git-annex-test-sshkey"
      {
        nativeBuildInputs = [ pkgs.openssh ];
      }
      ''
        mkdir -p $out
        ssh-keygen -t ed25519 -N "" -C "git-annex-test" -f $out/id_ed25519
      '';

  gpgKey =
    pkgs.runCommand "git-annex-test-gpgkey"
      {
        nativeBuildInputs = [ pkgs.gnupg ];
      }
      ''
        export GNUPGHOME=$(mktemp -d)
        gpg --batch --pinentry-mode loopback --passphrase "" \
          --quick-generate-key "git-annex-test <test@example.com>" default default never
        mkdir -p $out
        gpg --batch --pinentry-mode loopback --passphrase "" \
          --export-secret-keys --armor > $out/key.asc
      '';
in
pkgs.testers.nixosTest {
  name = "git-annex-keys";
  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ ../default.nix ];
      services.git-annex = {
        enable = true;
        sshKeyFile = "${sshKey}/id_ed25519";
        gpgKeyFile = "${gpgKey}/key.asc";
        repositories.local = {
          path = "/var/lib/git-annex/local";
          description = "local";
        };
      };
      environment.systemPackages = [ pkgs.gnupg ];
    };

  testScript = ''
    machine.wait_for_unit("git-annex-gpg-import.service")
    machine.wait_for_unit("git-annex-init-local.service")

    # Repo initialized.
    machine.succeed("test -d /var/lib/git-annex/local/.git")

    # sshKeyFile installed for the git-annex user, mode 600, correct owner.
    machine.succeed("test -f /var/lib/git-annex/.ssh/id_ed25519")
    machine.succeed("stat -c '%a %U' /var/lib/git-annex/.ssh/id_ed25519 | grep '600 git-annex'")

    # gpgKeyFile imported into the git-annex user's keyring (secret key included,
    # so it is usable for git-annex pubkey/hybrid decryption).
    machine.succeed(
        "sudo -u git-annex env HOME=/var/lib/git-annex gpg --list-secret-keys | grep test@example.com"
    )

    print("SUCCESS: ssh and gpg key install paths verified.")
  '';
}
