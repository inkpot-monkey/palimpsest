{
  self,
  config,
  pkgs,
  ...
}:

{

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

    # auto-sub
  ];

  # sops.secrets."apikey@api.deepinfra.com" = {
  #   sopsFile = self + /secrets/secrets.yaml;
  # };

  # home.shellAliases = {
  #   auto-sub-remote = "DEEPINFRA_API_KEY=$(cat ${
  #     config.sops.secrets."apikey@api.deepinfra.com".path
  #   }) ${pkgs.auto-sub}/bin/auto-sub --url https://api.deepinfra.com/v1/openai/audio/transcriptions";
  # };
}
