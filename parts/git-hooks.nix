{
  perSystem =
    { config, ... }:
    {
      # treefmt is the single formatting/linting entrypoint (nixfmt, deadnix,
      # statix, ruff, rustfmt, shfmt, taplo, prettier, mdformat, elisp-autofmt).
      # The pre-commit hook just runs it with --fail-on-change on staged files.
      pre-commit.settings.hooks.treefmt = {
        enable = true;
        package = config.treefmt.build.wrapper;
      };
    };
}
