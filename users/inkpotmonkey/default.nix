rec {
  cli =
    { ... }:
    {
      imports = [ ./bundle.nix ];
      custom.users.inkpotmonkey.identity.profile = "cli";
    };
  gui =
    { ... }:
    {
      imports = [ ./bundle.nix ];
      custom.users.inkpotmonkey.identity.profile = "gui";
    };
}
