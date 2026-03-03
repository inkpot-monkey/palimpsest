{ pkgs, ... }:
let
  buildPiApp = pkgs.writeShellApplication {
    name = "build-pi";
    runtimeInputs = with pkgs; [
      gnused
      sops
      ssh-to-age
      openssh
      zstd
      util-linux
      coreutils
      libnotify
    ];
    text = ''
      set -euo pipefail

      if [[ -z "''${NIXOS_REPO_ROOT:-}" ]]; then
          export NIXOS_REPO_ROOT
          NIXOS_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
      fi

      exec bash "${./build-pi.sh}" "$@"
    '';
  };
in
{
  type = "app";
  program = "${buildPiApp}/bin/build-pi";
}
