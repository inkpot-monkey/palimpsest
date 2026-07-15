# Shared helpers for the git-annex NixOS VM tests.
#
# The single shared ed25519 keypair below is installed on every node both as the
# git-annex user's private key (via services.git-annex.sshKeyFile) and as an
# authorized key. Because every node holds the same private key and authorizes
# its own public key, full-mesh SSH trust exists at boot with no testScript
# steps. This means the per-repo init oneshots succeed on first boot (no manual
# key exchange, no "restart the init service" dance) and removes the copy-pasted
# scaffolding the tests used to carry.
#
# NOTE: the key lives in /nix/store (world-readable) which is fine for ephemeral
# test VMs. Production must point sshKeyFile at a sops-managed path instead.
{ pkgs }:
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
in
{
  inherit sshKey;

  # A NixOS module fragment that every git-annex test node imports. It pulls in
  # the module under test, enables sshd, and wires up the shared key.
  commonNode =
    { ... }:
    {
      imports = [ ../default.nix ];

      services.openssh.enable = true;
      services.openssh.settings.MaxStartups = "100:30:200";
      networking.firewall.allowedTCPPorts = [ 22 ];

      services.git-annex.enable = true;
      services.git-annex.sshKeyFile = "${sshKey}/id_ed25519";
      users.users.git-annex.openssh.authorizedKeys.keyFiles = [ "${sshKey}/id_ed25519.pub" ];

      # Host-key verification is handled by the module's managed ~/.ssh/config
      # (StrictHostKeyChecking accept-new), so no extra test wiring is needed.
    };
}
