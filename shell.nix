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
      nh

      nodejs
      vscode-langservers-extracted
      marksman # markdown LSP (ADR/CONTEXT doc navigation)

      simple-http-server

      typescript-language-server
      bash-language-server
      prettier
      yaml-language-server
      svelte-language-server

      # Infrastructure
      vpsfree-client
      gh # GitHub CLI (PRs, issues, Actions)
      cachix # push uncached kernel outputs to palebluebytes.cachix.org (see `just cache-kernel`)

      # Secrets
      sops
      ssh-to-age

      # Python (e.g. pkgs/finance-tools): basedpyright is eglot's LSP
      # (types/completion/nav); ruff drives in-editor lint via flymake-ruff
      # (same rules as the treefmt commit gate) and `ruff check` on the CLI.
      basedpyright
      ruff

      # Rust (e.g. pkgs/annas-opds: cargo test / clippy / rustfmt)
      cargo
      rustc
      rustfmt
      clippy
      rust-analyzer
      pkg-config
      openssl

      # Advanced Rust development utilities
      mold
      bacon
      cargo-nextest
      cargo-watch
    ];

  };
}
