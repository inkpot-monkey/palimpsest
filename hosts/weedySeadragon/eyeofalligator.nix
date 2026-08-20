# eyeofalligator's HOST-side setup on weedySeadragon.
#
# eyeofalligator's account + home are bound turnkey from the `users` flake (hosts/default.nix), so
# the contract realizes the login account and the pre-built home carries its packages. What the
# contract deliberately does NOT carry (it takes no package/service input, ADR-0004) is the
# system-level setup a desktop co-admin needs — display-adjacent services, Steam, Flatpak, printing,
# etc. That is host policy, so it lives here rather than smuggled through a "user" module. Moved
# verbatim from the retired users/eyeofalligator/nixos binding, minus its home-manager wiring (now
# the turnkey bind) and the redundant login-shell (defaults to bashInteractive).
{
  pkgs,
  self,
  ...
}:
{
  # Flatpak & Discover support.
  services.flatpak.enable = true;
  environment.systemPackages = [
    pkgs.kdePackages.discover
    pkgs.kdePackages.flatpak-kcm
  ];

  # Steam.
  programs.steam.enable = true;

  # Tailscale + Bluetooth (weedySeadragon also enables these for the host; the booleans merge).
  custom.profiles.tailscale.enable = true;
  custom.profiles.bluetooth.enable = true;

  # Printing & Scanning.
  services.printing.enable = true;
  hardware.sane.enable = true;

  # KDE Connect.
  programs.kdeconnect.enable = true;

  # Silent auto-updates.
  system.autoUpgrade = {
    enable = true;
    allowReboot = false;
    flake = self.outPath;
    flags = [
      "--update-input"
      "nixpkgs"
      "--commit-lock-file"
    ];
    dates = "04:00";
  };

  # Compatibility (run unpatched dynamic binaries).
  programs.nix-ld.enable = true;
}
