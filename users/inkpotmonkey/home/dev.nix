{
  pkgs,
  config,
  lib,
  ...
}:
{
  options.custom.home.profiles.dev = {
    enable = lib.mkEnableOption "development tools and LSPS";
  };

  config = lib.mkIf config.custom.home.profiles.dev.enable {
    home.packages = with pkgs; [
      # Dev utilities
      nixd
      nixfmt
      prettierd
      sops
      ssh-to-age

      # Language Servers
      pyright
      nodePackages.typescript-language-server
      vscode-langservers-extracted
      rust-analyzer
      clang-tools
      astro-language-server
      glslang
    ];
  };
}
