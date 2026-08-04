# Integration VM for the repo-split capstone (issue #1, T4): the fleet binds the external
# `users` flake via the contract's pre-built binding (bindContractPackage, ADR-0016), on a
# synthetic seat — proving the loop WITHOUT touching any production host.
#
#   - `exposed` (kelpy role): binds the crypto-free BASE contractPackage, grants workstation.
#     The account materializes and the real home activates from the pre-built package.
#
# The seat binds a GENERIC test user ("testuser", a throwaway password) built from the SAME real
# home modules — so the rig never fabricates an account from the real user's identity/credentials.
# The contract's OWN conformance proves bindContractPackage generically (synthetic package); this
# proves it against the actual external home modules, the boundary ADR-0004 draws.
#
# (The former `trusted` signing seat was retired when the contract narrowed to "no secrets beyond
# the login credential" and the user repo dropped the signing feature — issue #1 follow-up.)
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

  # Common seat scaffold (./seat-base.nix). The user's LINGER is NOT set here: bindContractPackage
  # lingers the bound user itself, and the testScript asserts it, so this rig proves the binding
  # enforces linger (it is no longer a per-seat responsibility).
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
            workstation.enable = true;
          };
        })
      ];
      custom.host.exposed = true;
    };

  testScript = ''
    start_all()

    # ---- exposed seat: the account materializes and the real home activates ----
    exposed.wait_for_unit("multi-user.target")
    exposed.wait_for_unit("contract-activate-testuser.service")
    exposed.succeed("getent passwd testuser")
    # bindContractPackage lingers the bound user (not the seat) — the home's user services persist.
    exposed.succeed("test -e /var/lib/systemd/linger/testuser")
    exposed.succeed("getent passwd testuser | cut -d: -f5 | grep -qx 'Test User'")
    # A real home-manager home activated from the pre-built package (a managed dotfile is present).
    exposed.succeed("test -e /home/testuser/.config/git/config")
    print(exposed.succeed("id testuser"))
    print(exposed.succeed("su -l testuser -c 'git --version'"))
  '';
}
