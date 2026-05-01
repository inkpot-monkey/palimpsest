{
  perSystem = _: {
    pre-commit.settings.hooks = {
      nixfmt.enable = true;
      deadnix.enable = true;
      statix.enable = true;
    };
  };
}
