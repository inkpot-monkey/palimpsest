# kernel.nix
{ pkgs, ... }:

let
  kernel = pkgs.linuxPackages_rpi4.kernel.override {
    argsOverride = {
      src = pkgs.linuxPackages_rpi4.kernel.src;
      modDirVersion = pkgs.linuxPackages_rpi4.kernel.modDirVersion;
      kernelDTOverlays = [ "hifiberry-amp60" "hifiberry-dacplusadcpro" ];
    };
  };
in { boot.kernelPackages = kernel; }
