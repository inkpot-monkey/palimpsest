{
  self,
  inputs,
  ...
}:

{
  imports = [
    # Hardware
    ./hardware-configuration.nix
    inputs.nixos-hardware.nixosModules.framework-11th-gen-intel

    # Profiles
    self.nixosProfiles.bundle
  ];

  custom.profiles = {
    base.enable = true;
    audio.enable = true;
    wireless.enable = true;
    gui.enable = true;
    kanata.enable = true; # keyboard remap, host-side (contract ADR-0002 slice 11)
    bluetooth.enable = true;
    sops.enable = true;
    fonts.enable = true;
    monitoring-client.enable = true; # node-exporter + Vector; scraped by MagicDNS name

    tailscale = {
      enable = true;
      acceptDns = true;
    };
  };

  # User grants live in the fleet grant matrix (hosts/default.nix), not here.

  # weedySeadragon hosts two gui users (inkpotmonkey Wayland + eyeofalligator X11).
  # The display surface is NOT set here — it is derived from the union of each
  # granted gui user's `gui.session` by the contract realization (contract ADR-0003), so
  # both session types are offered and each user logs into their own.

  sops = {
    age.sshKeyPaths = [ "/home/inkpotmonkey/.ssh/id_ed25519" ];
  };

  # Safety Measure: Admin User — the break-glass account, assembled BY HAND here rather than bound
  # from the `users` flake, so this host can still be recovered if the primary login breaks.
  #
  # `resolveIdentity` completes the record. Neither identity surface carries option defaults any
  # more and the held identity is `readOnly`, so a PARTIAL record leaves fields with no definition
  # and forcing one is an eval error — the completion has to happen before the value is handed over
  # (contract ADR: identity is resolved once, and neither surface can author it).
  #
  # NO `extraGroups` HERE: an identity describes a person, never their powers, and the field is
  # gone from the schema. An account's groups now come from exactly two places, both somebody
  # else's decision — the session it was bound in, and what the host afforded. So `wheel` arrives
  # through the sudo grant in hosts/default.nix, and `networkmanager` — which is neither a contract
  # feature nor a session group — is set as plain NixOS config below.
  contract.users.admin.identity = inputs.contract.lib.resolveIdentity {
    username = "admin";
    name = "System Administrator";
    email = "admin@weedySeadragon.local";
    hashedPassword = "$6$Va8FcJEH8x9Hp/iL$EV3Nu3p9jqjin6rhbdQujHcX4LIsuxuzQOSfALpNqAO.LlZXNX/0EadRCfKx4FzqOKKUMGs6Ff4v8yarWjEpY1";
  };
  users.users.admin.extraGroups = [ "networkmanager" ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.efi.efiSysMountPoint = "/boot/efi";

  networking.hostName = "weedySeadragon";

  nixpkgs.buildPlatform.system = "x86_64-linux";

  # Power management for Framework laptop
  # power-profiles-daemon integrates better with KDE than TLP
  services.power-profiles-daemon.enable = true;

  # Network device discovery (mDNS)
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  system.stateVersion = "25.11";

  # beekeeper-studio is insecure. Contributed through the contract aggregator (which
  # merges) rather than nixpkgs.config directly (which would clobber the gui electron
  # permit). The Claude Desktop electron permit is contributed in inkpotmonkey's own
  # binding; the aggregator merges the two so both survive.
  contract.insecurePackages = [ "beekeeper-studio-5.5.7" ];
}
