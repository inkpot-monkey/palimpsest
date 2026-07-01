{
  perSystem =
    { pkgs, lib, ... }:
    let
      # elisp-autofmt has no upstream treefmt-nix program, so wrap an Emacs that
      # bundles the package and drive its batch entry point
      # (`elisp-autofmt-buffer-to-file') over each file. It shells out to a
      # bundled Python helper, so Python must be on PATH and the cache directory
      # writable — point the latter at a throwaway temp dir per run.
      emacsForFmt = (pkgs.emacsPackagesFor pkgs.emacs).withPackages (epkgs: [ epkgs.elisp-autofmt ]);
      elispAutofmt = pkgs.writeShellApplication {
        name = "elisp-autofmt-fmt";
        runtimeInputs = [
          emacsForFmt
          pkgs.python3
        ];
        text = ''
          cache="$(mktemp -d)"
          trap 'rm -rf "$cache"' EXIT
          emacs --batch --no-init-file \
            --eval "(progn
                      (setq elisp-autofmt-python-bin \"${pkgs.python3}/bin/python3\")
                      (setq elisp-autofmt-cache-directory \"$cache\")
                      (setq find-file-suppress-same-file-warnings t)
                      ;; Batch has no tty, so any prompt (e.g. \"changed on
                      ;; disk, reread?\") would read EOF and abort — auto-answer.
                      (fset 'yes-or-no-p (lambda (&rest _) t))
                      (fset 'y-or-n-p (lambda (&rest _) t))
                      (require 'elisp-autofmt)
                      ;; treefmt passes relative paths; \`find-file' mutates
                      ;; \`default-directory', so expand against a FIXED root or
                      ;; later relative paths resolve against the previous
                      ;; file's dir and compound into nonexistent paths.
                      (let ((root default-directory))
                        (dolist (f command-line-args-left)
                          (let ((path (expand-file-name f root)))
                            (find-file path)
                            ;; Format in-memory and write ONLY when the content
                            ;; actually changed: \`elisp-autofmt-buffer-to-file'
                            ;; rewrites unconditionally, bumping mtime every run,
                            ;; which makes treefmt's --fail-on-change fail
                            ;; forever on already-formatted files.
                            (let ((orig (buffer-string)))
                              (elisp-autofmt-buffer)
                              (unless (string= orig (buffer-string))
                                (write-region (point-min) (point-max) path nil 'silent)))
                            (set-buffer-modified-p nil)
                            (kill-buffer)))))" \
            "$@"
        '';
      };
    in
    {
      treefmt = {
        projectRootFile = "flake.nix";

        settings.global.excludes = [
          "*.lock"
          ".direnv/**"
          ".claude/**"
          "result"
          "result-*"
          # SOPS-encrypted — reformatting would corrupt the ciphertext layout.
          "**/secrets.yaml"
          "**/secrets.yaml.example"
          # Jinja2 templates: prettier would mangle the {% %} tags.
          "**/templates/*.html"
          # Binary / data / generated.
          "*.png"
          "*.pyc"
          "*.csv"
          "*.bean"
          "*.kbd"
          "*.xml"
          # project-agent skill files use YAML frontmatter that mdformat cannot
          # parse — it converts the --- delimiters to thematic breaks.
          "**/SKILL.md"
        ];

        programs = {
          # Nix — replaces the standalone git-hooks nixfmt/deadnix/statix hooks.
          deadnix.enable = true;
          statix.enable = true;
          nixfmt.enable = true;

          # Python — format + lint. ruff-check autofixes the safe cases (e.g.
          # unused imports) and fails the gate on the rest (bare except,
          # redefinitions), which is the point.
          ruff-format.enable = true;
          ruff-check.enable = true;

          # Rust (both crates are edition 2021; rustfmt defaults to 2015).
          rustfmt = {
            enable = true;
            edition = "2021";
          };

          # Shell.
          shfmt.enable = true;

          # TOML.
          taplo.enable = true;

          # TS / JS / YAML / JSON.
          prettier.enable = true;

          # Markdown.
          mdformat.enable = true;
        };

        # On a .nix file deadnix/statix rewrite then nixfmt cleans up after, so
        # nixfmt must run last.
        settings.formatter.deadnix.priority = 1;
        settings.formatter.statix.priority = 2;
        settings.formatter.nixfmt.priority = 3;

        # Keep prettier off Markdown (mdformat owns that) and off everything it
        # would otherwise greedily claim (css/html/etc.).
        settings.formatter.prettier.includes = lib.mkForce [
          "*.ts"
          "*.js"
          "*.yaml"
          "*.yml"
          "*.json"
        ];

        settings.formatter.elisp-autofmt = {
          command = lib.getExe elispAutofmt;
          includes = [ "*.el" ];
        };
      };
    };
}
