# The sops *binding* for the contract platform interface (ADR-0021): the one place that
# names `sops.*`. It realizes the backend-neutral provisioning seam
# (custom.platform.secrets / secretTemplates) onto sops-nix, and publishes the runtime
# paths and placeholders back through the interface for features to read.
#
# This is host/consumer-side, NOT contract-side — swapping to agenix is a matter of
# importing an `age` binding here instead, with no change to the contract or to any
# feature module. Imported wherever sops-nix is the home secrets backend (cli.nix).
{
  lib,
  config,
  ...
}:
let
  p = config.custom.platform;
in
{
  config = {
    # Logical secret requests → sops secrets. `key` is set only when given, so sops's
    # own default-key behaviour is preserved for single-key sources.
    sops.secrets = lib.mapAttrs (
      _: s: { sopsFile = s.source; } // lib.optionalAttrs (s.key != "") { inherit (s) key; }
    ) p.secrets;
    sops.templates = lib.mapAttrs (_: t: { inherit (t) content; }) p.secretTemplates;

    # Publish the runtime paths + placeholders back through the interface.
    custom.platform.secretPaths = lib.mapAttrs (n: _: config.sops.secrets.${n}.path) p.secrets;
    custom.platform.placeholder = lib.mapAttrs (n: _: config.sops.placeholder.${n}) p.secrets;
    custom.platform.templatePaths = lib.mapAttrs (
      n: _: config.sops.templates.${n}.path
    ) p.secretTemplates;
  };
}
