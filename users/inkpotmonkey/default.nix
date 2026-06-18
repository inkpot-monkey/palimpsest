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
      # Choosing the gui variant is the host's grant of the gui feature (ADR-0015).
      custom.users.inkpotmonkey.granted.gui.enable = true;
    };
}
