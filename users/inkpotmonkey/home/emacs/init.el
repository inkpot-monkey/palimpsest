;;; init.el --- Init File -*- lexical-binding: t -*-

(setq native-comp-async-report-warnings-errors 'silent)
(setq warning-minimum-level :error)

;; package.el is intentionally NOT initialized: every package comes from Nix
;; (emacsWithPackagesFromUsePackage, alwaysEnsure = true), whose generated
;; site-start sets up the load-path and autoloads at startup. Calling
;; `package-initialize' would re-activate ~/.config/emacs/elpa and shadow the
;; Nix-provided packages on load-path — the cause of the stale `sops-edit-file'
;; autoload bug. Nothing is installed via package.el or package-vc.
(require 'use-package)
(setq use-package-always-ensure nil)

;; --- Site/identity facts (Nix seam) -----------------------------------------
;; Host- and user-specific values are injected by Nix as a generated
;; `my-site-config.el' (see users/inkpotmonkey/home/emacs/default.nix), loaded
;; below. The `defvar' fallbacks keep this init.el valid, loadable, and
;; byte-compilable on its own — no @token@ string-substitution required, so the
;; file can be tested outside Nix. The generated module is the prod adapter; the
;; fallbacks are the dev adapter.
(defvar my-site/username "inkpotmonkey"
  "User full name. Overridden by the Nix-generated `my-site-config.el'.")
(defvar my-site/email ""
  "User mail address. Overridden by the Nix-generated `my-site-config.el'.")
(defvar my-site/secrets-file nil
  "Path to the sops secrets file for auth-source.
Overridden by the Nix-generated `my-site-config.el'.")
(defvar my-site/treesit-load-path nil
  "Directory holding compiled tree-sitter grammars.
Overridden by the Nix-generated `my-site-config.el'.")
(load (locate-user-emacs-file "my-site-config") :noerror :nomessage)

(use-package no-littering
    :config
  (no-littering-theme-backups)

  (require 'recentf)
  (add-to-list 'recentf-exclude
							 (recentf-expand-file-name no-littering-var-directory))
  (add-to-list 'recentf-exclude
							 (recentf-expand-file-name no-littering-etc-directory)))

(use-package gcmh
    :init (gcmh-mode)
    :custom
    (gcmh-idle-delay 5)
    (gcmh-high-cons-threshold (* 16 1024 1024))) ;; 16mb

(use-package emacs
    :init
  ;; General Settings
  (set-default-coding-systems 'utf-8)
  (setq save-interprogram-paste-before-kill t)

  ;; -- Clipboard Integration --
  (setq select-enable-clipboard t)
  (setq select-enable-primary t)
  
  (setq treesit-extra-load-path (delq nil (list my-site/treesit-load-path)))

  ;; -- Global Modes --
  (delete-selection-mode t)
  (recentf-mode t)
  (global-auto-revert-mode t)
  (global-so-long-mode t)
  (global-prettify-symbols-mode t)
  (abbrev-mode)
  (winner-mode t)
  (repeat-mode)
  (electric-pair-mode t)

  :custom
  ;; -- User Details --
  (user-full-name my-site/username)
  (user-mail-address my-site/email)

  ;; -- UI & Visuals --
  (visible-bell t)
  (use-file-dialog nil)
  (frame-resize-pixelwise t)
  (x-stretch-cursor t)
  (column-number-mode t)
  (bidi-paragraph-direction 'left-to-right)
  (bidi-inhibit-bpa t)
  (tab-width 2)
	(truncate-string-ellipsis "…")
	
  ;; -- Behavior --
  (confirm-kill-emacs 'yes-or-no-p)
  (sentence-end-double-space nil)
  (use-short-answers t)
  (vc-follow-symlinks t)
  (password-cache-expiry nil)
  (set-mark-command-repeat-pop t)

  ;; -- Indentation --
  (tab-always-indent 'complete)
  (lisp-indent-function 'common-lisp-indent-function)

  ;; -- Window Management --
  (window-combination-resize t)

  ;; -- Scrolling --
  (scroll-margin 2)
  (scroll-preserve-screen-position t)
  (fast-but-imprecise-scrolling t)
  (auto-window-vscroll nil)
  (scroll-conservatively 101)
  (pixel-scroll-precision-mode t)

  ;; -- Backups --
  (create-lockfiles nil)
  (delete-old-versions t)
  (kept-new-versions 10)
  (kept-old-versions 5)
  (version-control t)
	(delete-by-moving-to-trash t)
  (backup-by-copying t)

  ;; -- Undo Limits --
  (undo-limit 67108864)
  (undo-strong-limit 100663296)
  (undo-outer-limit 1006632960)

  (global-auto-revert-non-file-buffers t)

  ;; -- MiniBuffer --
  ;; Enable context menu. `vertico-multiform-mode' adds a menu in the minibuffer
  ;; to switch display modes.
  (context-menu-mode t)
  ;; Support opening new minibuffers from inside existing minibuffers.
  (enable-recursive-minibuffers t)
  ;; Hide commands in M-x which do not work in the current mode.  Vertico
  ;; commands are hidden in normal buffers. This setting is useful beyond
  ;; Vertico.
  (read-extended-command-predicate #'command-completion-default-include-p)
  ;; Do not allow the cursor in the minibuffer prompt
  (minibuffer-prompt-properties
   '(read-only t cursor-intangible t face minibuffer-prompt))

  (text-mode-ispell-word-completion nil)

  :config
  ;; -- Custom Functions --
  (defun goto-top-if-no-region+ (orig-func &rest args)
    "If region is not active, go to the buffer start."
    (save-excursion
      (when (not (use-region-p))
				(goto-char (point-min)))
      (apply orig-func args)))

  (advice-add 'query-replace :around #'goto-top-if-no-region+)
  (advice-add 'query-replace-regexp :around #'goto-top-if-no-region+)

  (defun unpop-to-mark-command+ ()
    "Unpop off mark ring. Does nothing if mark ring is empty."
    (interactive)
    (when mark-ring
      (setq mark-ring (cons (copy-marker (mark-marker)) mark-ring))
      (set-marker (mark-marker) (car (last mark-ring)) (current-buffer))
      (when (null (mark t)) (ding))
      (setq mark-ring (nbutlast mark-ring))
      (goto-char (marker-position (car (last mark-ring))))))

  (defun insert-secure-random-hex (arg)
    "Generate a secure 64-character hex token.
With a prefix ARG, save it to the kill ring instead of inserting it."
    (interactive "P")
    (let ((token (substring (shell-command-to-string "openssl rand -hex 32") 0 -1)))
      (if arg
          (progn
            (kill-new token)
            (message "Token copied to kill ring."))
        (insert token))))

  :bind
  ("M-z" . zap-up-to-char)
  ("M-%" . query-replace-regexp)
	("C-z" . undo)
	("C-S-z" . undo-redo))

(use-package prog-mode
    :ensure nil
    :bind (:map prog-mode-map
								("C-c l" . display-line-numbers-mode)))

(use-package savehist
    :ensure nil ; Built-in
    :custom
    (savehist-autosave-interval 60)
    :init
    (savehist-mode))

(use-package crux
		:bind
  ("M-o" . crux-other-window-or-switch-buffer)
  ("C-k" . crux-smart-kill-line)
  ("C-a" . crux-move-beginning-of-line)
  ("s-j" . crux-top-join-line)
  ("C-c e" . crux-eval-and-replace)
  ("C-<return>" . crux-smart-open-line-above)
  ("C-c r" . crux-rename-file-and-buffer)
  ("C-g" . crux-keyboard-quit-dwim)
  :config
  (crux-with-region-or-buffer indent-region)
  (crux-with-region-or-buffer untabify))

(use-package posframe)


(use-package goggles
    :hook ((prog-mode text-mode) . goggles-mode)
    :custom
    (goggles-pulse t))

(use-package exec-path-from-shell
		:init
  (when (or (daemonp)
            (memq window-system '(mac ns x pgtk)))
    (exec-path-from-shell-initialize))

  :config
  (dolist (var '("NIX_PATH" 
                 "NIX_SSL_CERT_FILE"))
    (add-to-list 'exec-path-from-shell-variables var)))

(use-package vundo)

(use-package undo-fu-session
		:custom
	(undo-fu-session-incompatible-files '("/COMMIT_EDITMSG\\'" "/git-rebase-todo\\'"))
	:config
	(undo-fu-session-global-mode))

(use-package info-colors
		:hook
	(Info-selection . info-colors-fontify-node))

(use-package which-key
		:config
	(which-key-mode))

(use-package helpful
		:bind
	([remap describe-function] . helpful-callable)
	([remap describe-command] . helpful-command)
	([remap describe-variable] . helpful-variable)
	([remap describe-symbol] . helpful-symbol)
	([remap display-local-help] . helpful-at-point)
	([remap describe-key] . helpful-key))

(use-package elisp-demos
		:after helpful
		:config
		(advice-add 'helpful-update :after #'elisp-demos-advice-helpful-update))

(use-package eros
		:config
	(eros-mode t))

(use-package wgrep
		:after embark
		:custom (wgrep-auto-save-buffer t)
		:bind
		(:map embark-collect-mode-map
					("i" . wgrep-change-to-wgrep-mode))
		(:map wgrep-mode-map
					("s-e" . wgrep-finish-edit)
					("s-k" . wgrep-abort-changes)))

;; sops 0.2 is a rewrite: decryption is transparent via `global-sops-mode'
;; (find-file-hook decrypts on open, save-buffer re-encrypts) — so opening any
;; sops file with `C-x C-f' just works, and the old manual commands are gone.
;; `sops-find-file' still exists (for creating a new encrypted file) but needs
;; no key; call it with `M-x' on the rare occasion.
(use-package sops
		:init
	(global-sops-mode t))

(use-package auth-source-sops
		:demand t
		:custom
		(auth-source-sops-file my-site/secrets-file)
		(auth-sources '(sops))
		(auth-source-save-behavior nil)
		:config
		(auth-source-sops-enable))

(use-package fontaine
		:custom
	(fontaine-presets 
	 '((regular
			:default-family ("Rec Mono Linear" "Monospace")
			:default-weight regular
			:default-height 120
			:variable-pitch-family "Recursive Sans Casual Static")))
	:init
	(fontaine-set-preset (or (fontaine-restore-latest-preset) 'regular))
	(fontaine-mode 1))

(use-package spacious-padding
		:custom
	(spacious-padding-subtle-mode-line
	 '( :mode-line-active spacious-padding-subtle-mode-line-active
		 :mode-line-inactive spacious-padding-subtle-mode-line-inactive))
	(spacious-padding-widths
	 '(:internal-border-width 15
		 :header-line-width 4
		 :mode-line-width 3
		 :tab-width 4
		 :right-divider-width 15
		 :scroll-bar-width 8
		 :fringe-width 8))
	:init
	(spacious-padding-mode))

(use-package ef-themes
		:init
	;; This forces the `modus-themes-` commands (rotate, toggle, select)
	;; to work on the Ef items collection instead of Modus.
	(ef-themes-take-over-modus-themes-mode 1)
	
	:bind
	(("<f5>" . modus-themes-rotate)
	 ("C-<f5>" . modus-themes-select)
	 ("M-<f5>" . modus-themes-load-random))
	
	:custom
	;; Use ef-specific variables for styling (Ef themes don't read modus variables)
	(ef-themes-mixed-fonts t)
	(ef-themes-italic-constructs t)
	(ef-themes-variable-pitch-ui t) 
	
	;; Retaining your previous heading configuration which is cleaner
	(ef-themes-headings
	 '((0 extrabold 1.5)
		 (t variable-pitch 1.0)))

	;; Define which themes to rotate between when pressing <f5>
	(ef-themes-to-toggle '(ef-summer ef-winter)) 

	:config
	;; Load the theme using the modus loader (safe because of the takeover mode)
	(modus-themes-load-theme 'ef-summer))

(use-package org
		:defer t
		:custom
		(org-todo-keywords '((sequence "TODO(t)" "IN PROGRESS(p)" "BLOCKED(b)" "|" "DONE(d)" "CANCELED(c)")))
		:config
		(defun my/org-setup-fonts ()
			(dolist (face '(org-level-1 org-level-2 org-level-3 org-level-4
											org-level-5 org-level-6 org-level-7 org-level-8))
				(set-face-attribute face nil :family "Montserrat" :weight 'bold)))
		(add-hook 'org-mode-hook #'my/org-setup-fonts))

(use-package visual-fill-column
		:custom
	(visual-fill-column-width 70)  ;; Explicitly set width
	(visual-fill-column-center-text t)
	(visual-fill-column-enable-sensible-window-split t)
	(visual-fill-column-adjust-for-text-scale t)  ;; Explicit is better

	:init
	(advice-add 'text-scale-adjust :after #'visual-fill-column-adjust))

(use-package adaptive-wrap
		:ensure t 
		:config
		(setq-default adaptive-wrap-extra-indent 0))

(use-package form-feed
		:config
	(global-form-feed-mode))

(use-package nerd-icons
		;; :custom
		;; The Nerd Font you want to use in GUI
		;; "Symbols Nerd Font Mono" is the default and is recommended
		;; but you can use any other Nerd Font if you want
		;; (nerd-icons-font-family "Symbols Nerd Font Mono")
		)

(use-package rainbow-delimiters
		:hook
	(prog-mode . rainbow-delimiters-mode))

(use-package dired
		:ensure nil
		:custom
		(dired-dwim-target t)
		(dired-auto-revert-buffer t)
		;; -a (all), -l (long), -t (time/date), -h (human readable)
		(dired-listing-switches "-alth")
		:hook 
		(dired-mode . dired-hide-details-mode)
		(dired-mode . dired-omit-mode)
		:bind
		(:map dired-mode-map
					("-" . dired-up-directory)
					("i" . dired-toggle-read-only))) 

(use-package diredfl
		:hook (dired-mode . diredfl-mode)) 

(use-package dired-git-info
		:bind (:map dired-mode-map
								(")" . dired-git-info-mode)))

(use-package dired-subtree
		:after dired
		:bind
		(:map dired-mode-map
					("<tab>" . dired-subtree-toggle)
					("TAB" . dired-subtree-toggle)
					("<backtab>" . dired-subtree-remove)
					("S-TAB" . dired-subtree-remove))
		:custom
		(dired-subtree-use-backgrounds nil))

(use-package wdired
		:ensure nil
		:after dired
		:custom
		(wdired-allow-to-change-permissions t)
		(wdired-use-interactive-rename t)
		(wdired-confirm-overwrite t)
		(wdired-use-dired-vertical-movement 'sometimes)
		:bind
		(:map wdired-mode-map
					("s-q" . wdired-exit)))

;; Transcribe marked audio/video files with WhisperX (CLI provided on stargazer).
;; C-c C-t in dired. Settings (model etc.) are set once via the `whisperx-*' vars.
(use-package whisperx
		:after dired
		:bind (:map dired-mode-map
								("C-c C-t" . whisperx-transcribe-dired)))

(use-package nerd-icons-dired
		:hook (dired-mode . nerd-icons-dired-mode))

(use-package dired-sidebar
		:bind ("C-x C-n" . dired-sidebar-toggle-sidebar)
		:custom
		(dired-sidebar-theme 'nerd)
		(dired-sidebar-use-term-integration t)
		(dired-sidebar-use-custom-font t))

(use-package ibuffer-sidebar
		:commands (ibuffer-sidebar-toggle-sidebar)
		:bind ("C-x C-p" . ibuffer-sidebar-toggle-sidebar))

(use-package avy
		:bind ("M-j" . avy-goto-char-timer)
		(:map goto-map ("l" . avy-goto-line))
		:custom
		(avy-timeout-seconds 0.3))

(use-package link-hint
		:bind ("M-J" . link-hint-open-link))

(use-package move-text
		:config
	(move-text-default-bindings))

(use-package visible-mark
		:init
	(defface visible-mark-active
			`((((type tty) (class mono)))
				(t (:underline ,(face-attribute 'cursor :background))))
		"Active mark face."
		:group 'visible-mark)
	:custom
	(visible-mark-max 1)
	(visible-mark-faces '(visible-mark-active))
	:config
	(global-visible-mark-mode +1))

(use-package orderless
		:custom
		;; Configure a custom style dispatcher (see the Consult wiki)
		;; (orderless-style-dispatchers '(+orderless-consult-dispatch orderless-affix-dispatch))
		;; (orderless-component-separator #'orderless-escapable-split-on-space)
		(completion-styles '(orderless basic))
		(completion-category-overrides '((file (styles partial-completion))))
		(completion-pcm-leading-wildcard t)) ;; Emacs 31: partial-completion behaves like substring

(use-package vertico
		:init
	(vertico-mode)
	:custom
	(vertico-cycle t)
	(vertico-resize t)
	(vertico-buffer-display-action '(display-buffer-in-direction (direction . right))))

(use-package vertico-directory
		:after vertico
		:ensure nil
		:bind (:map vertico-map
								("RET" . vertico-directory-enter)
								("DEL" . vertico-directory-delete-char)
								("M-DEL" . vertico-directory-delete-word))
		:hook (rfn-eshadow-update-overlay . vertico-directory-tidy))

(use-package corfu
		:custom
	(corfu-cycle t)
	(corfu-popupinfo-hide nil)
	(corfu-scroll-margin 5)
	
	:bind
	(:map corfu-map
				("M-q" . corfu-quick-complete)
				("RET" . corfu-send)
				("M-m" . corfu-move-to-minibuffer))
	
	:init
	(global-corfu-mode)
	(require 'corfu-history)
	(corfu-history-mode)
	(require 'corfu-quick)
	(require 'corfu-popupinfo)
	(corfu-popupinfo-mode)

	;; Setup Repeat Map for Popup Info
	(defvar corfu-popupinfo-navigation-repeat-map
		(let ((map (make-sparse-keymap)))
			(define-key map "n" #'corfu-popupinfo-scroll-up)
			(define-key map "p" #'corfu-popupinfo-scroll-down)
			(define-key map ">" #'corfu-popupinfo-end)
			(define-key map "<" #'corfu-popupinfo-beginning)
			(define-key map "d" #'corfu-popupinfo-documentation)
			(define-key map "l" #'corfu-popupinfo-location)
			(define-key map "t" #'corfu-popupinfo-toggle)
			map))

	(dolist (cmd '(corfu-popupinfo-scroll-up corfu-popupinfo-scroll-down 
								 corfu-popupinfo-end corfu-popupinfo-beginning 
								 corfu-popupinfo-documentation corfu-popupinfo-location 
								 corfu-popupinfo-toggle))
		(put cmd 'repeat-map 'corfu-popupinfo-navigation-repeat-map))

	(add-to-list 'corfu-continue-commands #'corfu-move-to-minibuffer))

(use-package marginalia
		:bind (:map minibuffer-local-map
								("M-A" . marginalia-cycle))
		:init
		(marginalia-mode t))

(use-package consult
		:hook (completion-list-mode . consult-preview-at-point-mode)
		:init
		;; Register preview
		(setq register-preview-delay 0.5
					register-preview-function #'consult-register-format)
		(advice-add #'register-preview :override #'consult-register-window)
		;; Xref integration
		(setq xref-show-xrefs-function #'consult-xref
					xref-show-definitions-function #'consult-xref)
		:config
		(setq consult-ripgrep-args (concat consult-ripgrep-args " --follow"))
		(setq consult-narrow-key "<")
		:bind (;;; C-c bindings in `mode-specific-map'
					 ("C-c M-x" . consult-mode-command)
					 ("C-c h" . consult-history)
					 ("C-c k" . consult-kmacro)
					 ("C-h M" . consult-man)
					 ;; orig. describe-input-method
					 ("C-h I" . consult-info) 
					 ([remap Info-search] . consult-info)

					 ("C-c i" . consult-org-heading)
					 
         ;;; C-x bindings in `ctl-x-map'
					 ;; orig. repeat-complex-command
					 ("C-x M-:" . consult-complex-command)
					 ;; orig. switch-to-buffer
					 ("C-x b" . consult-buffer)
					 ;; orig. switch-to-buffer-other-window
					 ("C-x 4 b" . consult-buffer-other-window)
					 ;; orig. switch-to-buffer-other-frame
					 ("C-x 5 b" . consult-buffer-other-frame)
					 ;; orig. switch-to-buffer-other-tab
					 ("C-x t b" . consult-buffer-other-tab)
					 ;; orig. bookmark-jump
					 ("C-x r b" . consult-bookmark)            
					 
         ;;; Custom M-# bindings for fast register access
					 ("M-#" . consult-register-load)
					 ;; orig. abbrev-prefix-mark (unrelated)
					 ("M-'" . consult-register-store)          
					 ("C-M-#" . consult-register)
					 
         ;;; Other custom bindings
					 ;; orig. yank-pop
					 ("M-y" . consult-yank-pop)                

					 :map project-prefix-map
					 ;; orig. project-switch-to-buffer
					 ("b" . consult-project-buffer)
					 
					 ;; consult-ripgrep defaults to project root if it decides its in a project
					 ;; to interactively set where to start the ripgrep call it with the universal
					 ;; prefix
					 ;; orig. project-find-regexp
					 ("g" . consult-ripgrep)             
					 
					 :map search-map
					 ;; M-s bindings in `search-map'
					 ("f" . consult-fd)
					 ("c" . consult-locate)
					 ("g" . consult-ripgrep)
					 ("G" . consult-git-grep)
					 ("l" . consult-line)
					 ("L" . consult-line-multi)
					 ("k" . consult-keep-lines)
					 ("u" . consult-focus-lines)
					 ;; Isearch integration
					 ("e" . consult-isearch-history)

					 ;; M-g bindings in `goto-map' 
					 :map goto-map
					 ("e" . consult-compile-error)
					 ;; Alternative: consult-flycheck
					 ("f" . consult-flymake)
					 ("F" . (lambda () (interactive) (consult-flymake '(4))))
					 ;; Alternative: consult-org-heading
					 ("o" . consult-outline)
					 ("m" . consult-mark)
					 ("k" . consult-global-mark)
					 ("i" . consult-imenu)
					 ("I" . consult-imenu-multi)
					 ("L" . consult-goto-line)
					 
					 :map isearch-mode-map
					 ("M-e" . consult-isearch-history)
					 ;; orig. isearch-edit-string
					 ("M-s e" . consult-isearch-history)
					 ;; needed by consult-line to detect isearch
					 ("M-s l" . consult-line)
					 ("M-s L" . consult-line-multi)
					 
					 ;; Minibuffer history
					 :map minibuffer-local-map
					 ;; orig. next-matching-history-element
					 ("M-s" . consult-history)
					 ;; orig. previous-matching-history-element
					 ("M-r" . consult-history)))

(use-package just-ts-mode
		:mode ("\\Justfile\\'" . just-ts-mode))

(use-package just-complete
		:bind (("C-c j" . just-run+)))


(use-package embark
		:bind
	(("C-." . embark-act)         ;; pick some comfortable binding
	 ("C-;" . embark-dwim)        ;; good alternative: M-.
	 ("C-h B" . embark-bindings)) ;; alternative for `describe-bindings'

	:init

	;; Optionally replace the key help with a completing-read interface
	(setq prefix-help-command #'embark-prefix-help-command)

	;; Show the Embark target at point via Eldoc. You may adjust the
	;; Eldoc strategy, if you want to see the documentation from
	;; multiple providers. Beware that using this can be a little
	;; jarring since the message shown in the minibuffer can be more
	;; than one line, causing the modeline to move up and down:

	;; (add-hook 'eldoc-documentation-functions #'embark-eldoc-first-target)
	;; (setq eldoc-documentation-strategy #'eldoc-documentation-compose-eagerly)

	;; (add-hook 'context-menu-functions #'embark-context-menu 100)

	:config
	;; Hide the mode line of the Embark live/completions buffers
	(add-to-list 'display-buffer-alist
							 '("\\`\\*Embark Collect \\(Live\\|Completions\\)\\*"
								 nil
								 (window-parameters (mode-line-format . none)))))

;; Consult users will also want the embark-consult package.
(use-package embark-consult
		:hook
		(embark-collect-mode . consult-preview-at-point-mode))

(use-package corfu-candidate-overlay
		:after corfu
		:config
		(corfu-candidate-overlay-mode t))

(use-package cape
		:bind ("C-c p" . cape-prefix-map) 
		:init
		(add-hook 'prog-mode-hook (lambda () (add-hook 'completion-at-point-functions #'cape-file nil t)))
		(add-hook 'comint-mode-hook (lambda () (add-hook 'completion-at-point-functions #'cape-file nil t)))
		
		:config
		(defun my/completion-at-point ()
			(cape-wrap-super
			 #'cape-abbrev
			 #'cape-dabbrev
			 #'cape-keyword))

		(add-hook 'completion-at-point-functions #'my/completion-at-point))

(use-package tempel
		
		:bind (("M-+" . tempel-complete) 
					 ("M-*" . tempel-insert))

		:config
		;; (global-tempel-abbrev-mode)
		)

(use-package tempel-collection
		:after tempel)

(use-package nerd-icons-completion
		:after marginalia
		:init
		(nerd-icons-completion-mode)
		:hook
		(marginalia-mode . nerd-icons-completion-marginalia-setup))

(use-package nerd-icons-corfu
		:after corfu
		:config
		(add-to-list 'corfu-margin-formatters #'nerd-icons-corfu-formatter))

(use-package pdf-tools
		:init
	(pdf-loader-install))

(use-package popup)
(use-package projectile)

;; ghostel — libghostty terminal, the claude-code backend (renders the Claude
;; TUI most faithfully, no eat-style repaint ghosting). The native module ships
;; prebuilt in the Nix package, so never let ghostel try to download/compile it.
(use-package ghostel
		:custom
		(ghostel-module-auto-install nil)
		;; Keys that pass through to Emacs instead of being sent to Claude's TUI.
		;; The default list is C-c/C-x/C-u/C-h/M-x/M-:/C-\; add M-o so global
		;; `crux-other-window-or-switch-buffer' still works from a Claude buffer,
		;; and M-s so `search-map' (M-s g = consult-ripgrep) reaches Emacs. C-x is
		;; already here, so the C-x p prefix (C-x p f = project-find-file) works too.
		(ghostel-keymap-exceptions
		 '("C-c" "C-x" "C-u" "C-h" "M-x" "M-:" "C-\\" "M-o" "M-s"))
		:config
		;; --- claude-code.el <-> ghostel 0.31 API shim ----------------------------
		;; stevemolitor/claude-code.el (<=0.4.5, == current upstream HEAD) targets
		;; ghostel's pre-0.31 mode API, but ghostel 0.31 reworked it: the
		;; `ghostel--copy-mode-active' flag was dropped in favour of buffer-local
		;; `ghostel--input-mode' (= `copy while in copy/read-only mode), and
		;; `ghostel-copy-mode-exit' was renamed to `ghostel-readonly-exit'. Without
		;; this bridge, opening Claude Code signals `void-variable
		;; ghostel--copy-mode-active' during window-size adjustment, which aborts the
		;; resize and leaves the buffer short. Drop this once claude-code.el adopts
		;; the new API upstream.
		(unless (fboundp 'ghostel-copy-mode-exit)
			(defalias 'ghostel-copy-mode-exit #'ghostel-readonly-exit))
		(defvar-local ghostel--copy-mode-active nil
			"Compat shim for claude-code.el; mirrors (eq ghostel--input-mode 'copy).")
		(add-variable-watcher
		 'ghostel--input-mode
		 (lambda (_sym newval op where)
			 (when (eq op 'set)
				 (with-current-buffer (or where (current-buffer))
					 (setq-local ghostel--copy-mode-active (eq newval 'copy)))))))

;; stevemolitor/claude-code.el — Claude Code as a full-window coding agent.
;; Multiple named sessions per project: claude-code (C-c c c), a second agent
;; with claude-code-new-instance, or claude-code-start-in-directory; switch
;; between them with claude-code-select-buffer (C-c c b). Defaults to the eat
;; backend. Buffers are named *claude:<dir>[:name]*.
;;
;; Keys: C-c c is the command prefix (C-c c m = transient menu).
(use-package claude-code
		:bind-keymap ("C-c c" . claude-code-command-map)
		:custom
		;; libghostty backend — faithful TUI render, no eat repaint ghosting.
		(claude-code-terminal-backend 'ghostel)
		;; MUST be nil for the ghostel backend. claude-code's resize optimisation
		;; (=t) wraps the backend's process-window-size fn with :around advice that
		;; returns nil on height-only changes to suppress the SIGWINCH. That model
		;; assumes a *pure* size-calculator (true for eat/vterm). But ghostel
		;; (>=0.34) made `ghostel--window-adjust-process-window-size' impure: it
		;; resizes its own grid + redraws synchronously as a side effect, then
		;; relies on Emacs sending the SIGWINCH afterwards. The advice runs that
		;; side-effecting resize but then returns nil → SIGWINCH suppressed → the
		;; Claude CLI never learns the new row count. ghostel renders at the new
		;; height while Claude's TUI still believes the old one, so its bottom
		;; spinner/input frame repaints at the wrong row and leaves a stale copy
		;; (the duplicated "Recombobulating…" + doubled input box). ghostel already
		;; does this reflow-avoidance itself, so the advice is redundant anyway.
		(claude-code-optimize-window-resize nil)
		;; Full window, not the default split-below: route display through
		;; display-buffer so the same-window rule below applies. Reuses the
		;; selected window (full height + width); switch buffers to get back to
		;; code. Leaves any other windows you've split intact.
		(claude-code-display-window-fn #'display-buffer)
		:config
		(add-to-list 'display-buffer-alist
								 '("\\`\\*claude:" (display-buffer-same-window))))

;; Package + feature are both `ai-code' (packages.nix; main library is
;; `ai-code.el', which `(provide 'ai-code)'). trivialBuild emits no autoloads,
;; so `:bind' autoloads `ai-code-menu' from the `ai-code' feature directly.
(use-package ai-code
		;; Enable global keybinding for the main menu
		:bind
		(("C-, g" . ai-code-menu))
		:config
		(ai-code-set-backend 'gemini) 
		;; Optional: Set up Magit integration for AI commands in Magit popups
		(with-eval-after-load 'magit
			(ai-code-magit-setup-transients)))

(use-package gptel
		:init
	(add-to-list 'auto-mode-alist '("\\.llm\\'" . org-mode))
	(with-eval-after-load 'nerd-icons
		(add-to-list 'nerd-icons-extension-icon-alist
								 '("llm" nerd-icons-mdicon "nf-md-robot" :face nerd-icons-lsilver)))
	
	:hook
	(org-mode . (lambda ()
								(when (and buffer-file-name
													 (string-suffix-p ".llm" buffer-file-name))
									(gptel-mode 1))))
	;; Ensure abbrevs work in gptel-mode
	(gptel-mode . (lambda ()
									(setq local-abbrev-table gptel-mode-abbrev-table)))

	:config
	(require 'gptel-integrations)

	;; Your API/Backend Setup
	(gptel-make-anthropic "Claude" :stream t :key gptel-api-key)
	(setq gptel-model 'gemini-pro-latest)
	(setq gptel-backend (gptel-make-gemini "Gemini" :stream t :key gptel-api-key))
	
	;; Default mode for NEW buffers
	(setq gptel-default-mode 'org-mode)

	;; Custom Abbrevs
	(define-abbrev-table 'gptel-mode-abbrev-table
			'(("eyt" "explain your thinking step by step" nil :count 0)))
	
	:bind
	(("C-c RET" . gptel-send)
	 ("C-, s" . gptel-send)
	 ("C-, A" . gptel-abort)
	 ("C-, a" . gptel-add)
	 ("C-, m" . gptel-menu)
	 :map gptel-mode-map
	 ("C-c RET" . gptel-send)
	 ("C-, s" . gptel-send)
	 ("C-, A" . gptel-abort)
	 ("C-, a" . gptel-add)
	 ("C-, m" . gptel-menu)))

(use-package mcp
		:after gptel
		:config
		(require 'mcp-hub)
		:init (mcp-hub-start-all-server))

(use-package daemons)

(use-package journalctl-mode
		:bind (("C-c t" . journalctl)))

(use-package proced
		:ensure nil
		:defer t
		:custom
		(proced-enable-color-flag t)
		(proced-tree-flag t))

(use-package eww
		:ensure nil
		:bind
	("s-w" . eww))

(use-package recall
		:bind
	("C-x C-r" . recall-rerun)
	:custom
	(recall-save-file (concat no-littering-var-directory "recall/history"))
	(recall-directory (concat no-littering-var-directory "recall/"))
	;; Consult completion based interface
	(recall-completing-read-fn #'recall-consult-completing-read)
	:init
	;; Enable process surveillance
	(recall-mode t)
	(run-with-idle-timer 60 t (lambda ()
															(recall-save))))

(use-package org
		:after (cape tempel)
		:bind
		("C-c l" . org-store-link)
		:hook
		((org-mode . visual-line-fill-column-mode)
		 (org-mode . adaptive-wrap-prefix-mode)))

(use-package org-agenda
		:ensure nil
		:after org
		:config
		(require 'org-agenda))

(use-package org-capture
		:ensure nil
		:after org
		:custom
		(org-default-notes-file (concat org-directory "/calendar.org"))
		:config
		(setq org-capture-templates
					'(("e" "Events")
						("ep" "Personal event" entry
						 (file+headline "calendar.org" "Personal")
						 "* %^{Event}\n%^T\n%?\n"
						 :empty-lines-before 1
						 :append t)
						)))

(use-package markdown-mode
		:mode ("README\\.md\\'" . gfm-mode)
		:bind
		(:map markdown-mode-map
					("C-c V" . markdown-view-mode))
		(:map markdown-view-mode-map
					("C-c V" . markdown-mode))
		(:map markdown-mode-map
					("C-c v" . gfm-view-mode))
		(:map gfm-view-mode-map
					("C-c v" . gfm-mode))
		:custom
		(markdown-command "multimarkdown")
		:hook
		(markdown-mode . visual-fill-column-mode)
		(markdown-view-mode . visual-fill-column-mode))

(define-derived-mode open-docx-as-markdown+ markdown-view-mode "DOCX View"
										 "Major mode for viewing .docx files as markdown."
										 (let ((filename (buffer-file-name)))
											 (when (and filename (file-exists-p filename))
												 (let ((inhibit-read-only t))
													 (erase-buffer)
													 (insert (shell-command-to-string (format "pandoc -f docx -t markdown %s" (shell-quote-argument filename))))
													 (set-buffer-modified-p nil)
													 (read-only-mode 1)
													 (goto-char (point-min))))))

(add-to-list 'auto-mode-alist '("\\.docx\\'" . open-docx-as-markdown+))



(use-package text-mode
		:ensure nil
		:hook
		((text-mode . visual-line-fill-column-mode)
		 (text-mode . adaptive-wrap-prefix-mode)))

(use-package magit
		:custom
	;; Makes Ediff much more usable
	(ediff-window-setup-function 'ediff-setup-windows-plain)
	(ediff-split-window-function 'split-window-horizontally)
	:bind (("s-m m" . magit-status)
				 ("s-m j" . magit-dispatch)
				 ("s-m k" . magit-file-dispatch)
				 ("s-m l" . magit-log-buffer-file)
				 ("s-m b" . magit-blame)))

(use-package git-modes
		:mode
	("/\\.dockerignore\\'" . gitignore-mode))

(use-package verb
		:config 
	(define-key org-mode-map (kbd "C-c C-r") verb-command-map))

(use-package eglot
		:hook ((nix-ts-mode rust-ts-mode js-ts-mode html-ts-mode css-ts-mode yaml-ts-mode json-ts-mode) . eglot-ensure)
		:custom
		(eglot-ignored-server-capabilities
		 '(:documentFormattingProvider
			 :documentRangeFormattingProvider
			 :documentOnTypeFormattingProvider))
		(eglot-events-buffer-size 0)
		:bind
		(:map eglot-mode-map
					("C-c r" . eglot-rename)
					("C-c o" . eglot-code-action-organize-imports)
					("C-c a" . eglot-code-actions)
					("C-c i" . eglot-inlay-hints-mode))
		:config
		;; Drastically improves performance in large projects
		(fset #'jsonrpc--log-event #'ignore)
		
		(setq completion-category-defaults nil)
		(advice-add 'eglot-completion-at-point :around #'cape-wrap-buster)
		
		(defun my/eglot-capf ()
			(add-hook 'completion-at-point-functions
								(cape-capf-super #'eglot-completion-at-point #'cape-abbrev)
								nil t))
		(add-hook 'eglot-managed-mode-hook #'my/eglot-capf))

(use-package project
		:ensure nil
		:config
		(defun project-run-ghostel+ ()
			"Open ghostel in the current project root."
			(interactive)
			(ghostel-project))

		(defun project-claude-code ()
			"Open Claude Code in the current project root."
			(interactive)
			(let ((default-directory (project-root (project-current t))))
				(claude-code)))

		(setq project-switch-commands
					'((project-find-file "Find file" ?f)
						(consult-ripgrep "Ripgrep" ?g)
						(consult-project-buffer "Buffer" ?b)
						(magit-project-status "Magit" ?m)
						(project-find-dir "Find directory" ?d)
						(project-run-ghostel+ "Ghostel" ?v)
						(project-claude-code "Claude Code" ?c)
						(project-any-command "Other" ?o)))

		:bind (:map project-prefix-map
								("m" . magit-project-status)
								("v" . project-run-ghostel+)
								("c" . project-claude-code)))

(use-package apheleia
		:init (apheleia-global-mode))

(use-package consult-eglot
		:after (eglot consult)
		:config
		;; Safely load the extension
		(require 'consult-eglot-embark nil t)
		(when (fboundp 'consult-eglot-embark-mode)
			(consult-eglot-embark-mode)))

(use-package eglot-tempel
		:after (eglot tempel)
		:config
		(eglot-tempel-mode t))


(use-package quickrun)

(use-package envrc
		:init
	(envrc-global-mode))

(use-package flymake
		:ensure nil
		:bind
		(:map flymake-mode-map
					("M-n" . flymake-goto-next-error)
					("M-p" . flymake-goto-prev-error)))

;;; --- Shell & Compilation ---

(use-package shell-command+
		:bind (([remap shell-command] . shell-command+)))

;; Front-load `shell-command-history' (savehist-persisted) as completion
;; candidates so `M-&' shows past commands immediately instead of an empty
;; prompt — pick-or-type, always in the current `default-directory'.  recall
;; still surveils every launch; `C-x C-r' (recall-rerun) remains the
;; rerun-in-original-context tool.
(use-package emacs
		:bind (([remap async-shell-command] . my/async-shell-command-from-history)
					 ("C-c &" . my/async-shell-command-rerun-last))
		:config
		(defun my/async-shell-command-from-history (command &optional output-buffer error-buffer)
			"Like `async-shell-command' but completes from `shell-command-history'.
COMMAND is read with `shell-command-history' as candidates (pick an old
command or type a new one).  OUTPUT-BUFFER and ERROR-BUFFER are passed
through unchanged, mirroring `async-shell-command' (prefix arg inserts
output at point)."
			(interactive
			 (list (completing-read "Async shell command: "
															shell-command-history
															nil nil nil 'shell-command-history)
						 current-prefix-arg
						 shell-command-default-error-buffer))
			(async-shell-command command output-buffer error-buffer))

		(defun my/async-shell-command-rerun-last ()
			"Rerun the most recent `shell-command-history' entry, no prompt.
Runs in the current `default-directory'.  For rerun in a command's
original directory use `recall-rerun' (\\[recall-rerun])."
			(interactive)
			(if-let ((command (car shell-command-history)))
					(progn (message "Rerunning: %s" command)
								 (async-shell-command command))
				(user-error "No shell command history yet"))))

;; In an async-shell-command output buffer, `g' reruns that buffer's own
;; command in place — same buffer, same `default-directory' — like
;; `g'/`recompile' in a compilation buffer.  Emacs already sets a buffer-local
;; `revert-buffer-function' to `(async-shell-command command buffer)'.
;;
;; But `shell-command-mode' derives from `comint-mode', so the buffer is
;; interactive: while a process is live you may be sending it stdin, and `g'
;; must self-insert.  So only hijack `g' once the process has exited (the
;; common case for async output); otherwise type it normally.
(use-package shell
		:ensure nil
		:bind (:map shell-command-mode-map
								("g" . my/async-shell-command-rerun-buffer))
		:config
		(defun my/async-shell-command-rerun-buffer (n)
			"Rerun this async-shell buffer's command, like compile's \\`g'.
If a process is still live in the buffer, self-insert instead (N times)
so stdin still works — only rerun once the command has exited."
			(interactive "p")
			(if (process-live-p (get-buffer-process (current-buffer)))
					(self-insert-command n)
				(revert-buffer-quick))))

(use-package compile-ansi
	:config
	(compile-ansi-setup))



(use-package ement
	:commands (ement-connect ement-list-rooms ement-view-room ement-describe-room)
	:custom
	(ement-save-sessions t)
	(ement-auto-sync t)
	(ement-initial-sync-timeout 40))

(use-package ement-glue
	:after ement
	:bind ("C-c m" . ement-glue-map))


(use-package nix-ts-mode
	:mode "\\.nix\\'"
	:custom
	(treesit-font-lock-level 4)
	:hook
	(nix-ts-mode . eglot-ensure))

(use-package nix-system
	:commands (nix-rebuild-system+ nix-update-system-flake+ nix-system-network-transient))

(use-package pretty-sha-path
		:init
	(global-pretty-sha-path-mode))

(use-package rust-ts-mode
		:ensure nil
		:hook
		(rust-ts-mode . eglot-ensure)
		
		:config
		(add-to-list 'eglot-server-programs
								 '((rust-ts-mode rust-mode) .
									 ("rust-analyzer"
										:initializationOptions
										(:check (:command "clippy")))))
		
		(add-to-list 'project-vc-extra-root-markers "Cargo.toml"))

(use-package sh-mode
		:ensure nil

		:mode
		(".env" . sh-mode)

		:hook
		;; Make shebang (#!) file executable when saved
		(after-save . executable-make-buffer-file-executable-if-script-p)

		:config
		(org-babel-do-load-languages
		 'org-babel-load-languages
		 (append org-babel-load-languages
						 '((shell . t)))))

(use-package js-ts-mode
		:ensure nil
		:mode "\\.cjs\\'"
		:init
		(push '(javascript-mode . js-ts-mode) major-mode-remap-alist)
		:custom
		(global-subword-mode t)
		:hook
		(js-ts-mode . eglot-ensure))

(use-package typescript-ts-mode
		:ensure nil
		:demand
		:mode "\\.ts\\'"
		:hook
		(typescript-ts-mode . eglot-ensure))

(use-package html-ts-mode
		:ensure nil
		:mode (("\\.webc\\'" . html-ts-mode)   
					 ("\\.html?\\'" . html-ts-mode)) 
		:init
		(push '(html-mode . html-ts-mode) major-mode-remap-alist)
		:bind (:map html-ts-mode-map
								("M-o" . nil)
								("C-c o O" . font-lock-fontify-block)
								("C-c o b" . facemenu-set-bold)
								("C-c o d" . facemenu-set-default)
								("C-c o i" . facemenu-set-italic)
								("C-c o l" . facemenu-set-bold-italic)
								("M-O" . facemenu-set-face)
								("C-c o u" . facemenu-set-underline))
		:hook
		(html-ts-mode . eglot-ensure))

(use-package svelte-ts-mode
		:demand t
		:after eglot
		:config
		(add-to-list 'eglot-server-programs '(svelte-ts-mode . ("svelteserver" "--stdio"))))

(use-package astro-ts-mode
		:mode "\\.astro\\'")

(use-package css-ts-mode
		:ensure nil
		:no-require
		:after eglot
		:custom
		(css-indent-offset 2)
		:init
		(push '(css-mode . css-ts-mode) major-mode-remap-alist)
		:hook
		(css-ts-mode . eglot-ensure))

(use-package lorem-ipsum)   

(use-package glsl-mode)

(use-package yaml
		:ensure nil
		:mode ("\\.yaml\\'" . yaml-ts-mode)
		:hook
		(yaml-ts-mode . eglot-ensure))

(use-package json
		:ensure nil
		:init
		(push '(js-json-mode . json-ts-mode) major-mode-remap-alist)
		:hook
		(json-ts-mode . eglot-ensure))

(use-package php-mode)

;;; Network Management
(use-package enwc
		:custom
	(enwc-default-backend 'nm)
	(enwc-auto-scan t)
	(enwc-nm-edit-settings-in-new-frame nil))

(use-package consult-omni
	:after consult
	:init
	(let ((dir (file-name-directory (locate-library "consult-omni"))))
		(when dir
			(add-to-list 'load-path (expand-file-name "sources" dir))
			(add-to-list 'load-path (expand-file-name "apps" dir))))
	(require 'consult-omni)
	(require 'consult-omni-sources)
	(require 'consult-omni-apps)

	:custom
	(consult-async-min-input 2)
	(consult-omni-show-preview nil)
	(consult-omni-group-by nil)

	:config
	;; Set 'Apps' as the primary source for the launcher
	(setq consult-omni-multi-sources '("Apps"))

	(defun consult-omni--apps-callback (cand)
		"Callback to launch an application from a `consult-omni' candidate.
This directly spawns the process as a child of the Emacs daemon to
ensure it persists and captures any startup errors in a dedicated
buffer (*App: Name*)."
		(let* ((cmd (get-text-property 0 :exec cand))
					 ;; Strip desktop-file placeholders (e.g., %u, %f)
					 (clean-cmd (and cmd (replace-regexp-in-string " %[a-zA-Z].*" "" cmd))))
			(if clean-cmd
				(let ((buffer-name (format "*App: %s*" (get-text-property 0 :title cand))))
					(message "Launching %s..." clean-cmd)
					(start-process-shell-command
					 "nixos-app"
					 (generate-new-buffer buffer-name)
					 clean-cmd))
				(message "Error: No executable found for %s" (get-text-property 0 :title cand)))))

	:bind
	("C-c s" . consult-omni-launch))

(use-package consult-omni-launch
	:commands (consult-omni-launch))

(use-package sly
		:commands (sly sly-connect)
		
		:custom
		(inferior-lisp-program "sbcl")
		
		(sly-symbol-completion-mode 'radix)
		
		:config
		(sly-setup '(sly-fancy))
		
		:bind
		(:map sly-mode-map
					("M-." . sly-edit-definition)
					("C-c C-d h" . sly-documentation-lookup)))

(use-package sly-quicklisp
		:after sly)

(use-package sly-asdf
		:after sly)

(use-package paredit
		:hook
	:disabled
	;; Hook into Sly REPL and standard Lisp mode
	((sly-mrepl-mode lisp-mode emacs-lisp-mode) . paredit-mode)
	:bind
	(:map paredit-mode-map
				;; Unbind keys that might conflict with your window manager if needed
				;; ("C-<left>" . nil) 
				;; ("C-<right>" . nil)
				))

(use-package scel
		:ensure nil
		:defer t
		:init
		(when-let ((env-path (getenv "EMACSLOADPATH")))
			(dolist (path (parse-colon-path env-path))
				(add-to-list 'load-path path)))

		:mode ("\\.scd\\'" . sclang-mode)
		
		:config
		;; -- Core Setup --
		(setq sclang-program "sclang")
		(setq sclang-runtime-directory nil)
		(setq sclang-max-post-buffer-size 16384)
		(setq sclang-auto-scroll-post-buffer t)

		;; -- Visuals --
		(add-hook 'sclang-post-buffer-hook 
							(lambda () 
								(visual-line-mode 1)
								(text-scale-set -1)))

		(add-hook 'sclang-mode-hook 
							(lambda () 
								(setq-local completion-at-point-functions 
														(list #'cape-dabbrev #'cape-file))))

		;; -- Pulse Effect --
		(advice-add 'sclang-eval-region-or-line :after
								(lambda (&rest _)
									(let ((beg (if (use-region-p) (region-beginning) (line-beginning-position)))
												(end (if (use-region-p) (region-end) (line-end-position))))
										(pulse-momentary-highlight-region beg end))))

		:bind 
		(:map sclang-mode-map
					("s-<return>" . sclang-eval-line)
					("C-c C-c" . sclang-eval-region-or-line)
					("C-c C-o" . sclang-server-boot)
					("C-." . sclang-stop)
					("C-c C-d" . sclang-find-help)))

(add-hook 'emacs-startup-hook
          (lambda ()
            (setq gc-cons-threshold (* 16 1024 1024))))
