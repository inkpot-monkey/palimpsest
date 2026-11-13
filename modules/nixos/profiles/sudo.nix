{
  config,
  lib,
  ...
}:

{
  options.custom.profiles.sudo = {
    enable = lib.mkEnableOption "passwordless sudo for the wheel group (deploy convenience)";
  };

  config = lib.mkIf config.custom.profiles.sudo.enable {
    # Allow wheel members to run sudo without a password. Access is already
    # gated by key-only SSH reachable only over the tailnet (profiles/ssh.nix,
    # ADR-0039), and this keeps remote `nixos-rebuild --sudo` deploys fully
    # non-interactive so they can't hang on a password prompt mid-deploy.
    security.sudo.wheelNeedsPassword = false;
  };
}
