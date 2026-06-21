# Platform interface — part of the host↔user contract (ADR-0015 mechanic 6, ADR-0021).
# The host implements this interface and the user's features consume it, so a feature
# names a *logical* secret and never the host's secrets **backend** (sops, agenix, …).
#
# Two layers, both backend-neutral at the feature's eye:
#   - resolvers (secretFile/secretPath): host-bound, return WHERE a logical secret group's
#     ciphertext lives. A path is a path; the host decides what it points at.
#   - provisioning (secrets → secretPaths): a feature DECLARES a logical secret and reads
#     its runtime path; the host **binding** realizes it on whatever backend. Features
#     never write `sops.*`; only the binding does.
#
# Why a typed option set rather than a specialArgs attrset: a host that fails to bind is a
# clear *option* error, not a late `attribute missing` (ADR-0015 Q6). Plaintext never
# appears at eval — only the decrypted runtime path, located at activation.
{ lib }:
{
  secretFile = lib.mkOption {
    type = lib.types.functionTo lib.types.path;
    description = "Resolve a named secret group to the ciphertext source the host backend reads.";
  };
  secretPath = lib.mkOption {
    type = lib.types.functionTo lib.types.path;
    description = "Resolve a secrets-repo subpath to the ciphertext source the host backend reads.";
  };

  # --- Provisioning seam (ADR-0021): logical secret in, runtime path out. ---
  secrets = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          source = lib.mkOption {
            type = lib.types.path;
            description = "Ciphertext source (from secretFile/secretPath); the host backend reads it.";
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
    description = "Logical secret requests a feature declares; the host's platform binding realizes them.";
  };
  secretPaths = lib.mkOption {
    type = lib.types.attrsOf lib.types.path;
    default = { };
    description = "Runtime path of each declared secret, populated by the host binding. Read, never set, by features.";
  };
}
