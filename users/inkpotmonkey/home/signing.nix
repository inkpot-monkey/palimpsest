# inkpotmonkey's commit-signing key, as a USER (home-sops) feature — mirroring
# restic.nix (ADR-0018, slice 13). The key is a dedicated NON-admin ed25519 key (see
# git.nix); riding the user's own home sops means it is decrypted by the user's own
# key, with no host re-key and no footprint on a headless/exposed host (which has no
# user key to decrypt it, and whose agent should not sign as the user anyway).
#
# Enabled per host by the signing grant (custom.home.profiles.signing.enable, wired
# from hostFacts.granted.signing in users/inkpotmonkey/nixos/default.nix).
{
  config,
  lib,
  ...
}:
{
  # The `signing.enable` option is declared centrally in the contract home-profile
  # vocabulary (contract/home-profiles.nix); this module supplies its config.
  config = lib.mkIf config.custom.home.profiles.signing.enable {
    sops.secrets.inkpotmonkey_signing_key = {
      key = "signing_key";
      # The host names where the encrypted source lives; the user decrypts it.
      sopsFile = config.custom.platform.secretPath "users/inkpotmonkey.yaml";
    };
  };
}
