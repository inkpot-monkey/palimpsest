{
  gui = {
    imports = [ ./nixos/default.nix ];
    config.identity.profile = "gui";
  };
  cli = {
    imports = [ ./nixos/default.nix ];
    config.identity.profile = "cli";
  };
}
