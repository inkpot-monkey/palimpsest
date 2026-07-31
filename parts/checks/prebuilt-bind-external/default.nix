# Integration VM for the repo-split capstone (issue #1, T4): the fleet binds the external
# `inkpotmonkey-home` flake via the contract's pre-built binding (bindContractPackage, ADR-0016),
# on two synthetic seats — proving the loop WITHOUT touching any production host.
#
#   - `exposed`  (kelpy role, AC #6): binds the crypto-free contractPackage, grants NO signing.
#     The account materializes and the real home activates, but git falls back to ~/.ssh and NO
#     signing secret is present — an exposed seat holds no feature secret.
#   - `trusted`  (AC #3): binds the signing variant over the COMMITTED TEST secrets, grants signing,
#     and holds the throwaway key so sops-nix decrypts the (dummy) signing key at runtime.
#
# Both seats bind a GENERIC test user ("testuser", a throwaway password) built from the SAME real
# home modules — so the rig never fabricates an account from the real user's identity/credentials.
# The contract's OWN conformance proves bindContractPackage generically (synthetic package); this
# proves it against the actual external home modules, the boundary ADR-0004 draws.
{
  pkgs,
  inputs,
  system,
}:
let
  inherit (inputs) contract;
  inherit (contract.lib) bindContractPackage loadIdentity;
  userHome = inputs.users;
  # GENERIC test identity — account "testuser", throwaway password (issue #1); never the real user.
  identity = loadIdentity (userHome + "/tests/identity.json");

  cpExposed = userHome.packages.${system}.contractPackage-test; # crypto-free generic
  cpTrusted = userHome.packages.${system}.contractPackage-signing-test; # signing over the test secrets
  # The committed THROWAWAY ssh key whose ssh-to-age is the test secrets' sole recipient. The trusted
  # seat plants it so sops-nix can decrypt the dummy signing key headlessly (guards nothing real).
  testKey = userHome + "/test-keys/id_ed25519";

  # Common seat scaffold (./seat-base.nix, shared with the eval sibling gui-eval.nix). The user's
  # LINGER — needed so the pre-built home's sd-switch/sops-nix user services have a running user
  # systemd instance — is NOT set here: bindContractPackage now lingers the bound user itself, and
  # the testScript asserts it, so this rig proves the binding enforces linger (it is no longer a
  # per-seat responsibility).
  seatBase = import ./seat-base.nix { inherit system; };
in
pkgs.testers.runNixOSTest {
  name = "prebuilt-bind-external";
  node.pkgsReadOnly = false;

  nodes.exposed =
    { ... }:
    {
      imports = [
        seatBase
        contract.nixosModules.default
        (bindContractPackage {
          contractPackage = cpExposed;
          inherit identity;
          grants = {
            workstation.enable = true; # NO signing — exposed seats never get a secret-bearing feature
          };
        })
      ];
      custom.host.exposed = true;
    };

  nodes.trusted =
    { ... }:
    {
      imports = [
        seatBase
        contract.nixosModules.default
        (bindContractPackage {
          contractPackage = cpTrusted;
          inherit identity;
          grants = {
            signing.enable = true;
            workstation.enable = true;
          };
        })
      ];
      custom.host.exposed = false;
      # Plant the throwaway decryption key BEFORE the activation service runs, so the home's
      # sops-nix (sops.age.sshKeyPaths = ~/.ssh/id_ed25519) can decrypt the test signing key.
      systemd.tmpfiles.rules = [
        "d /home/testuser/.ssh 0700 testuser users -"
        "C /home/testuser/.ssh/id_ed25519 0600 testuser users - ${testKey}"
      ];
    };

  testScript = ''
    start_all()

    # ---- exposed seat (AC #6): login-only, no feature secret ----
    exposed.wait_for_unit("multi-user.target")
    exposed.wait_for_unit("contract-activate-testuser.service")
    exposed.succeed("getent passwd testuser")
    # bindContractPackage lingers the bound user (not the seat) — the home's user services persist.
    exposed.succeed("test -e /var/lib/systemd/linger/testuser")
    exposed.succeed("getent passwd testuser | cut -d: -f5 | grep -qx 'Test User'")
    exposed.succeed("test -e /home/testuser/.config/git/config")
    signingkey = exposed.succeed(
        "su -l testuser -c 'git config --get user.signingkey'"
    ).strip()
    assert signingkey == "/home/testuser/.ssh/id_ed25519.pub", (
        f"exposed seat should use the ~/.ssh fallback, got {signingkey!r}"
    )
    # No feature secret on the exposed seat — and this is discriminating, not vacuous: the seat
    # both (a) never planted the user's age key, so it COULDN'T decrypt one, and (b) holds NO
    # decrypted material at all. The named-path check alone would pass trivially for the crypto-free
    # variant; pairing it with "no key present" + "the whole secret store is empty" proves the
    # exposed seat is genuinely bare (AC #6), which the trusted seat below then contrasts.
    exposed.fail("test -e /home/testuser/.config/sops-nix/secrets/testuser_signing_key")
    exposed.fail("test -e /home/testuser/.ssh/id_ed25519")  # no user decryption key was ever planted
    exposed.succeed(
        "test -z \"$(find /home/testuser/.config/sops-nix/secrets -type f 2>/dev/null)\""
    )  # the sops secret store holds nothing decrypted

    # ---- trusted seat (AC #3): signing resolves from the own secrets at runtime ----
    trusted.wait_for_unit("multi-user.target")
    trusted.wait_for_unit("contract-activate-testuser.service")
    trusted.succeed("getent passwd testuser")
    # git points at the sops-decrypted own-secrets secret, NOT the ~/.ssh fallback.
    tkey = trusted.succeed("su -l testuser -c 'git config --get user.signingkey'").strip()
    assert tkey == "/home/testuser/.config/sops-nix/secrets/testuser_signing_key", (
        f"trusted seat should sign with the own-secrets secret, got {tkey!r}"
    )
    # The secret actually decrypted at runtime (the sops path resolves to a non-empty file).
    trusted.succeed("test -s /home/testuser/.config/sops-nix/secrets/testuser_signing_key")
    # It is a real (dummy) ed25519 private key — sops-nix genuinely decrypted it.
    trusted.succeed(
        "grep -q 'OPENSSH PRIVATE KEY' /home/testuser/.config/sops-nix/secrets/testuser_signing_key"
    )

    print(trusted.succeed("id testuser"))
    print(trusted.succeed("su -l testuser -c 'git --version'"))
  '';
}
