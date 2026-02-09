{ inputs, ... }:
{
  perSystem =
    {
      pkgs,
      config,
      ...
    }:
    {
      devShells = import "${inputs.self}/shell.nix" { inherit pkgs; } // {
        default = (import "${inputs.self}/shell.nix" { inherit pkgs; }).default.overrideAttrs (old: {
          shellHook = ''
            ${old.shellHook or ""}
            ${config.pre-commit.installationScript}
          '';
        });
      };
    };
}
