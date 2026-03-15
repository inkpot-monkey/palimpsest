{
  config,
  lib,
  ...
}:

let
  cfg = config.custom.profiles.server;
in
{
  options.custom.profiles.server = {
    enable = lib.mkEnableOption "server base configuration (SSH)";
  };

  config = lib.mkIf cfg.enable {
    # This setups a SSH server. Very important if you're setting up a headless system.
    # Feel free to remove if you don't need it.
    services.openssh = {
      enable = true;
      # Forbid root login through SSH.
      settings = {
        # require public key authentication for better security
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
      };
    };
  };
}
