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
      # --- Dev Utilities ---
      nixd
      nixfmt
      prettierd
      sops
      ssh-to-age
      binutils
      unzip
      zip
      cmake
      editorconfig-core-c
      sqlite
      imagemagick
      pandoc
      libtool

      # --- Language Servers & Formatters ---
      # Nix
      nil
      nixfmt

      # Shell
      shfmt
      shellcheck
      bash-language-server

      # Web & Modern
      typescript-language-server
      vscode-langservers-extracted # html, css, json, eslint
      yaml-language-server
      svelte-language-server
      astro-language-server
      taplo # toml
      html-tidy
      stylelint
      jsbeautifier

      # Python
      python3
      black
      pyright

      # Systems & Graphics
      rust-analyzer
      clang-tools
      glslang
      dockerfile-language-server

      # Media & Docs
      texlive.combined.scheme-medium
    ];
  };
}
