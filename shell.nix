# Shell for bootstrapping flake-enabled nix and home-manager
# You can enter it through 'nix develop' or (legacy) 'nix-shell'

{
  pkgs,
}:
{
  default = pkgs.mkShell {

    packages = with pkgs; [
      lorri
      nixfmt
      statix
      nil
      just

      nodejs
      vscode-langservers-extracted

      simple-http-server

      nodePackages.typescript-language-server
      nodePackages.bash-language-server
      nodePackages.prettier
      nodePackages.yaml-language-server
      nodePackages.svelte-language-server

      # Infrastructure
      vpsfree-client

      # Secrets
      sops
      ssh-to-age
    ];

  };
}
