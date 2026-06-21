# The single writer of nixpkgs.config.permittedInsecurePackages (ADR-0018 review,
# finding 3). `nixpkgs.config` is types.attrs — it SHALLOW-merges, so two modules each
# setting permittedInsecurePackages CLOBBER rather than concatenate, and a host's value
# can silently drop a feature's permit.
#
# Funnel every host/feature permit through this mergeable list option, and write the real
# option exactly once. A feature (e.g. gui → electron) and a host (e.g. → beekeeper) then
# coexist instead of one winning. Imported on every host via the contract umbrella, so
# the option always exists.
{
  lib,
  config,
  ...
}:
{
  options.custom.insecurePackages = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "electron-39.8.10" ];
    description = "Insecure package names to permit. Merged across all contributors (features and hosts) and written once to nixpkgs.config.permittedInsecurePackages, which cannot itself merge.";
  };

  # The sole writer. Nothing else may set permittedInsecurePackages directly, or the
  # shallow merge returns: contribute via custom.insecurePackages instead.
  config.nixpkgs.config.permittedInsecurePackages = lib.unique config.custom.insecurePackages;
}
