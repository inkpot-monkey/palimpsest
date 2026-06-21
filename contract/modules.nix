# The contract's umbrella modules — one per eval-side (ADR-0020 Q2), split out of
# kit.nix (thermo-nuclear review). Each is closed over the registry projections + option
# fragments the kit computes, so it depends on neither `self` nor `inputs`. The host
# imports these and supplies only the `platform` binding (Q7).
{
  lib,
  realization,
  identityOptions,
  platformOptions,
  homeProfileOptions,
  grantedOptions,
  featureConfigOptions,
  exposedHostOffenders,
}:
{
  # System kit: the custom.users schema, the platform INTERFACE (host binds it), the
  # exposed-host marker + ban, and the realization + insecure aggregator. The host
  # imports this and supplies the platform binding.
  nixosModule =
    { config, ... }:
    {
      imports = [
        realization
        ./insecure-packages.nix
      ];

      options.custom.users = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              identity = identityOptions;
              granted = grantedOptions;
            }
            // featureConfigOptions;
          }
        );
        default = { };
        description = "Per-user identity, grants, and feature configuration.";
      };
      options.custom.platform = platformOptions;
      options.custom.host.exposed = lib.mkEnableOption "an exposed/agent-facing host that may not be granted secret-bearing features";

      config.assertions = lib.optional config.custom.host.exposed (
        let
          offending = exposedHostOffenders config;
        in
        {
          assertion = offending == [ ];
          message = "exposed host '${config.networking.hostName}' must not be granted secret-bearing feature(s): ${lib.concatStringsSep ", " offending}";
        }
      );
    };

  # Home kit: the identity + home-profile vocabulary + the platform INTERFACE (host
  # binds it). The home identity value is populated from the system identity by the host.
  homeModule = _: {
    options.identity = identityOptions;
    options.custom.home.profiles = homeProfileOptions;
    options.custom.platform = platformOptions;
  };
}
