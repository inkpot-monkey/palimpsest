# Shared synthetic-seat scaffold for the prebuilt-bind-external rig (default.nix, VM nodes) and its
# pure-eval sibling (gui-eval.nix): tmpfs root, no bootloader, and a stub HOST platform seam
# (orthogonal to the bound user's OWN home sops). Enough to evaluate — or boot — a bound `testuser`
# account without a real disk or a real secrets backend. Parameterized only by `system`.
{ system }:
{
  system.stateVersion = "25.11";
  nixpkgs.hostPlatform = system;
  boot.loader.grub.enable = false;
  fileSystems."/" = {
    device = "tmpfs";
    fsType = "tmpfs";
  };
  custom.platform = {
    secretFile = _: builtins.toFile "stub-secret" "";
    secretPath = _: builtins.toFile "stub-secret" "";
  };
}
