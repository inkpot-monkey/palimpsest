{
  config,
  lib,
  ...
}:

let
  cfg = config.custom.profiles.ssh;
in
{
  options.custom.profiles.ssh = {
    enable = lib.mkEnableOption "ssh server configuration";

    tailnetOnly = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Reach sshd over the tailnet only (ADR-0039). sshd still binds every
        interface; what changes is that nothing opens port 22 in the firewall,
        so the only path in is `tailscale0` — trusted wholesale by
        `custom.profiles.tailscale`. A port scan of the public address sees a
        filtered port rather than a key-only prompt.

        Set to false only for a host that must answer SSH from an untrusted
        network, and say why at the call site.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # This setups a SSH server. Very important if you're setting up a headless system.
    # Feel free to remove if you don't need it.
    services.openssh = {
      enable = true;
      # Tailnet-only reachability (ADR-0039). The module's default is to punch
      # port 22 through the firewall on every interface; this is the one line
      # that stops it. `custom.profiles.tailscale` puts `tailscale0` in
      # `trustedInterfaces`, which is what still lets the fleet in.
      openFirewall = !cfg.tailnetOnly;
      # Forbid root login through SSH.
      settings = {
        # require public key authentication for better security
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
      };
    };

    assertions = [
      {
        # Without tailscale there is no `tailscale0`, so tailnetOnly would leave
        # the host with no reachable SSH at all — a lockout that evaluates green.
        assertion = cfg.tailnetOnly -> config.custom.profiles.tailscale.enable;
        message = "custom.profiles.ssh.tailnetOnly is on for ${config.networking.hostName}, but custom.profiles.tailscale is not enabled — there would be no interface left to reach sshd on. Enable tailscale, or set custom.profiles.ssh.tailnetOnly = false and say why.";
      }
    ];
  };
}
