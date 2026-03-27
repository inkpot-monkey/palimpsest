rec {
  cli = ./bundle.nix;
  gui =
    { ... }:
    {
      imports = [ cli ];
      custom.users.inkpotmonkey.identity.profile = "gui";
    };
}
