# Platform interface — part of the host↔user contract (ADR-0015, mechanic 6).
# The host implements these resolvers and the user's features consume them, so a
# feature names a *logical* secret and never the host's secrets backend
# (self.lib.getSecret*). Typed options (functionTo path) rather than an untyped
# specialArgs attrset — a host that fails to bind the platform is a clear option
# error, not a late `attribute missing` (ADR-0015 Q6 worried specialArgs aren't
# type-checked; an option set is). The resolvers return the *encrypted* sops
# source — plaintext never appears at eval; the decrypted value is located at
# activation time via config.sops.secrets.<name>.path.
{ lib }:
{
  secretFile = lib.mkOption {
    type = lib.types.functionTo lib.types.path;
    description = "Resolve a named secret group to its encrypted sops source file.";
  };
  secretPath = lib.mkOption {
    type = lib.types.functionTo lib.types.path;
    description = "Resolve a secrets-repo subpath to its encrypted path.";
  };
}
