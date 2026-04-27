{
  perSystem = _: {
    pre-commit.settings.hooks = {
      nixfmt-rfc-style.enable = true;
      deadnix.enable = true;
      statix.enable = true;
    };
  };
}
