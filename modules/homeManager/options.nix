# Host-side home wiring for the contract (its ADR-0004): import the contract's umbrella home
# kit (identity + home-profile vocabulary + the platform interface) and supply the
# host's `platform` binding (Q7). The contract ships only the interface; the secrets
# backend is named here. The identity value is populated from the system identity via
# `inherit identity` in users/<user>/nixos/default.nix.
{
  self,
  inputs,
  lib,
  ...
}:
{
  imports = [ inputs.contract.homeModules.default ];

  # The backend-neutral platform SEAM (ADR-0005), vendored here. It FORMERLY lived in the
  # contract (declared by the home umbrella); the contract has since narrowed to "no secrets
  # beyond the login credential" and dropped the seam, so the fleet — which owns its own
  # secrets backend — now DECLARES the interface as well as binding it. Types match the retired
  # contract seam verbatim.
  options.custom.platform = {
    secretFile = lib.mkOption {
      type = lib.types.functionTo lib.types.path;
      description = "Resolve a named secret group to the ciphertext source the backend reads.";
    };
    secretPath = lib.mkOption {
      type = lib.types.functionTo lib.types.path;
      description = "Resolve a secrets-repo subpath to the ciphertext source the backend reads.";
    };
    secrets = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            source = lib.mkOption {
              type = lib.types.path;
              description = "Ciphertext source (from secretFile/secretPath); the backend reads it.";
            };
            key = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Logical key within the source group (multi-key backends like sops); single-file backends like agenix ignore it.";
            };
          };
        }
      );
      default = { };
      description = "Logical secret requests a feature declares; this binding realizes them on sops.";
    };
    secretPaths = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      description = "Runtime path of each declared secret, populated by this binding. Read, never set, by features.";
    };
  };

  # The host's secrets-backend binding (secretFile/secretPath), shared via self.lib.platformBinding
  # so the wiring lives in one place (ADR-0005). platform-sops.nix realizes the `secrets` seam.
  config.custom.platform = self.lib.platformBinding;
}
