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

    # ── The sops age identity ──────────────────────────────────────────────────────────
    # Every `sops` call made from this repo needs the &admin age identity, and sops cannot
    # find it on its own. Its ssh fallback looks for ~/.ssh/id_rsa; this fleet's admin key
    # is ~/.ssh/id_ed25519 (docs/adr/0003), so without the line below a bare
    # `sops secrets/profiles/<f>.yaml` fails with "Group 0: FAILED" against the &admin
    # recipient, and so do `sops updatekeys`, `just sops-recipients`, `nix run .#dns` and
    # `nix run .#push-relay-deploy`.
    #
    # SOPS_AGE_SSH_PRIVATE_KEY_FILE IS NOT THE ANSWER, and this is the trap worth knowing:
    # the problem is the key FORMAT, not the path. There are two incompatible ways to use
    # an ed25519 ssh key with age — age's native ssh support, which opens `ssh-ed25519`
    # recipient stanzas, and ssh-to-age, which converts the key to a native X25519 `age1…`
    # identity. This fleet is entirely the second: ADR-0003 defines &admin as ssh-to-age of
    # the operator's key, and sops-nix's `sops.age.sshKeyPaths` does the same conversion on
    # every host. That variable implements the FIRST, so pointing it at exactly the right
    # key still answers "no identity matched any of the recipients" (measured, 2df7172).
    # Teaching sops' ssh fallback about id_ed25519 would not help either, for the same
    # reason; making it work would mean re-keying every file in the fleet to a different
    # recipient type.
    #
    # SO DERIVE ON DEMAND, AND DECLARE IT HERE. SOPS_AGE_KEY_CMD takes the identity from a
    # command's stdout, so nothing is ever written to disk — deliberately NOT a persistent
    # ~/.config/sops/age/keys.txt. That file would work (and was briefly how this was
    # fixed), but it is undeclared manual state: nothing in either tree records that it has
    # to exist, so it does not survive a reinstall and its absence is a silent re-break.
    # That is exactly how palimpsest#216 came to be filed — the identity used to arrive
    # from a home-manager session variable pointing at a home-sops runtime file, and when
    # that left the tree in 9b785dc nothing recorded it had been load-bearing. The lesson
    # is not "env vars are fragile"; it is "put it where a reader will find it". Here, next
    # to the sops and ssh-to-age it feeds, is that place. It cannot live in the home
    # instead: ~/code/users provisions no secrets, by its own rule, deliberately.
    #
    # A shellHook rather than an `env` attribute, because `$HOME` must expand in bash at
    # shell entry; as a derivation attribute it would be passed through literally.
    #
    # Scope, stated: this covers sops run from inside a direnv'd clone of this repo, which
    # is every caller there is — the stash itself lives at ./secrets. Run sops from outside
    # and it fails the legible way, with the "Group 0: FAILED" above.
    shellHook = ''
      export SOPS_AGE_KEY_CMD="ssh-to-age -private-key -i $HOME/.ssh/id_ed25519"
    '';
  };
}
