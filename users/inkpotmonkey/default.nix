rec {
  cli = ./bundle.nix;
  gui =
    { lib, ... }:
    {
      imports = [ cli ];
      # Using mkForce to ensure it overrides the default in identity.nix
      identity.profile = lib.mkForce "gui";
    };
}
