{
  pkgs,
  inputs,
  self,
  keys,
  ...
}:
{
  imports = [ inputs.home-manager.nixosModules.home-manager ];

  users.users.inkpotmonkey = {
    isNormalUser = true;
    hashedPassword = "<SCRUBBED_PASSWORD>";
    extraGroups = [
      "input"
      "uinput"
      "podman"
      "docker"
      "plugdev"
      "disk"
      "qemu-libvirtd"
      "dialout"
      "libvirt"
      "networkmanager"
      "audio"
      "video"
      "wheel"
    ];
    shell = pkgs.bash;
    openssh.authorizedKeys.keys = [
      keys.personal.inkpotmonkey
    ];
  };

  users.groups = {
    libvirt.members = [ "inkpotmonkey" ];
    podman.members = [ "inkpotmonkey" ];
    uinput.members = [ "inkpotmonkey" ];
  };

  # Fix for XDG Desktop Portal with home-manager.useUserPackages
  environment.pathsToLink = [
    "/share/xdg-desktop-portal"
    "/share/applications"
  ];

  home-manager = {
    useUserPackages = true;
    useGlobalPkgs = true;
    extraSpecialArgs = {
      inherit
        inputs
        self
        keys
        ;

    };
    backupFileExtension = "backup";
    users.inkpotmonkey = import ./default.nix;
  };
}
