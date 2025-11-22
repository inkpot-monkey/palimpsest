{ ... }:

{
  users.users.root.openssh.authorizedKeys.keys = [
    "<SCRUBBED_SSH_KEY>"
  ];

  # This setups a SSH server. Very important if you're setting up a headless system.
  # Feel free to remove if you don't need it.
  services.openssh = {
    enable = true;
    # Forbid root login through SSH.
    settings = {
      # require public key authentication for better security
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

}
