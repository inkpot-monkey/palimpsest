rec {
  cli = ./bundle.nix;
  gui =
    { ... }:
    {
      imports = [ cli ];
      identity.profile = "gui";
    };
}
