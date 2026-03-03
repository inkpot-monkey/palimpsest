;;; init.el --- Modern Emacs Configuration  -*- lexical-binding: t; -*-

;; NOTE: Settings that must run absolutely first (GC tuning, UI disabling)
;; are kept top-level to ensure they run before any packages are loaded.

;; Performance tuning for startup
(setq gc-cons-threshold (* 50 1000 1000))

;; Restore gc-cons-threshold after startup
(add-hook 'emacs-startup-hook
          (lambda ()
            (setq gc-cons-threshold (* 2 1000 1000))))

;;; Minimal UI
(setq native-comp-async-report-warnings-errors nil) ; Silence native comp warnings
(menu-bar-mode -1)
(tool-bar-mode -1)
(scroll-bar-mode -1)
(set-fringe-mode 10)
(tooltip-mode -1)
(setq inhibit-startup-message t)
(setq visible-bell t)

;;; Package Management
(require 'package)
(setq package-enable-at-startup nil)

;;; Directories (No-Littering)
;; NOTE: Must be loaded early to keep .emacs.d clean
(use-package no-littering
		:config
  ;; Save auto-save files to a subfolder
  (setq auto-save-file-name-transforms
        `((".*" ,(no-littering-expand-var-file-name "auto-save/") t))))

;;; Environment (Shell Path)
(use-package exec-path-from-shell
		:if (or (daemonp) (memq window-system '(mac ns x pgtk)))
		:init
		(exec-path-from-shell-initialize))


;;; Emacs Core Settings
(use-package emacs
		:init
  ;; Global Keybindings
  (global-set-key (kbd "<escape>") 'keyboard-escape-quit)
  
  ;; Better Defaults
  (setq-default indent-tabs-mode t)     ; Use tabs
  (setq-default tab-width 2)            ; Tab width 2
  (setq-default c-basic-offset 2)       ; C-style 2 spaces (if spaces used)
  
  (electric-pair-mode 1)                ; Auto-close pairings
  (global-auto-revert-mode 1)           ; Auto-refresh buffers
  (setq global-auto-revert-non-file-buffers t)
  (repeat-mode 1)                       ; Enable repeat mode for repeatable commands
  (repeat-mode 1)                       ; Enable repeat mode for repeatable commands
  (delete-selection-mode 1)             ; Replace selection on paste
  (setq enable-recursive-minibuffers t) ; Enable recursive minibuffers
  (add-to-list 'default-frame-alist '(fullscreen . maximized)) ; Maximize on startup
  (winner-mode 1)                       ; Enable window layout undo/redo
  
  ;; Backup Settings (saved to ~/.config/emacs/var/backup/ via no-littering)
  (setq make-backup-files t          ; Enable backups
        version-control t            ; Use version numbers for files
        kept-new-versions 10         ; Keep newest versions
        kept-old-versions 0          ; Don't keep oldest versions
        delete-old-versions t        ; Delete excess backups silently
        backup-by-copying t)         ; Copy files to avoid permission issues
  (setq create-lockfiles nil)         ; Disable lock files (prevent .# files)
  
  ;; Quality of Life
  (setq fmakepound 'y-or-n-p)         ; Simplified confirmations
  (defalias 'yes-or-no-p 'y-or-n-p)   ; More robust y-or-n switch
  
  (recentf-mode 1)                    ; Track recent files
  (setq recentf-max-menu-items 25
        recentf-max-saved-items 50)
  
  (column-number-mode 1)              ; Show column number in mode line
  (setq-default sentence-end-double-space nil) ; Single space after sentences
  
  ;; Smooth Scrolling
  (setq scroll-margin 0
        scroll-conservatively 101     ; Don't jump when scrolling
        scroll-preserve-screen-position t
        auto-window-vscroll nil))


;;; File Management (Dired)
(use-package dired
		:ensure nil
		:custom
		(dired-listing-switches "-alht")              ; Sort by date (newest first), human readable
		(dired-dwim-target t)                         ; Suggest target directory for copy/move
		(dired-auto-revert-buffer t)                  ; Auto-refresh dired on file changes
		:bind (:map dired-mode-map
								("i" . wdired-change-to-wdired-mode))
		:hook
		(dired-mode . dired-omit-mode))

;;; Theme
(use-package ef-themes
		:demand t
		:config
		(ef-themes-take-over-modus-themes-mode 1)
		(load-theme 'ef-day t)
		
		(defun my/toggle-theme ()
			(interactive)
			(if (eq (car custom-enabled-themes) 'ef-night)
					(load-theme 'ef-summer t)
				(load-theme 'ef-night t)))
		
		:bind ("C-c t" . my/toggle-theme))


;;; Modern Completion Stack (Vertico, Consult, Orderless, Marginalia, Embark)

;; Vertico - Vertical Interactive Completion
(use-package vertico
		:init
  (vertico-mode)
  :custom
  (vertico-scroll-margin 0)
  (vertico-count 20)
  (vertico-resize t)
  (vertico-cycle t))

;; Persist history over Emacs restarts
(use-package savehist
		:ensure nil
		:init
		(savehist-mode))

;; Marginalia - Rich annotations in completion buffer
(use-package marginalia
		:bind (:map minibuffer-local-map
								("M-A" . marginalia-cycle))
		:init
		(marginalia-mode))

;; Orderless - Fuzzy matching
(use-package orderless
		:custom
  (completion-styles '(orderless basic))
  (completion-category-overrides '((file (styles basic partial-completion)))))

;; Consult - Useful search and navigation commands
(use-package consult
		:bind (;; C-c bindings in `mode-specific-map'
					 ("C-c M-x" . consult-mode-command)
					 ("C-c h" . consult-history)
					 ("C-c k" . consult-kmacro)
					 ("C-c m" . consult-man)
					 ("C-c i" . consult-info)
					 ([remap Info-search] . consult-info)
					 ;; C-x bindings (ctl-x-map)
					 ("C-x M-:" . consult-complex-command)     ;; orig. repeat-complex-command
					 ("C-x b" . consult-buffer)                ;; orig. switch-to-buffer
					 ("C-x 4 b" . consult-buffer-other-window) ;; orig. switch-to-buffer-other-window
					 ("C-x 5 b" . consult-buffer-other-frame)  ;; orig. switch-to-buffer-other-frame
					 ("C-x r b" . consult-bookmark)            ;; orig. bookmark-jump
					 ("C-x p b" . consult-project-buffer)      ;; orig. project-switch-to-buffer
					 ;; Custom M-# bindings for fast register access
					 ("M-#" . consult-register-load-delete)
					 ("M-'" . consult-register-store)
					 ("C-M-#" . consult-register)
					 ;; Other custom bindings
					 ("M-y" . consult-yank-pop)                ;; orig. yank-pop
					 ;; M-g bindings (goto-map)
					 ("M-g e" . consult-compile-error)
					 ("M-g f" . consult-flymake)               ;; Alternative: consult-flycheck
					 ("M-g g" . consult-goto-line)             ;; orig. goto-line
					 ("M-g M-g" . consult-goto-line)           ;; orig. goto-line
					 ("M-g o" . consult-outline)               ;; Alternative: consult-org-heading
					 ("M-g m" . consult-mark)
					 ("M-g k" . consult-global-mark)
					 ("M-g i" . consult-imenu)
					 ("M-g I" . consult-imenu-multi)
					 ;; M-s bindings (search-map)
					 ("M-s f" . consult-fd)           
					 ("M-s c" . consult-locate)
					 ("M-s g" . consult-ripgrep)
					 ("M-s G" . consult-git-grep)
					 ("M-s l" . consult-line)
					 ("M-s L" . consult-line-multi)
					 ("M-s k" . consult-keep-lines)
					 ("M-s u" . consult-focus-lines)
					 ;; Isearch integration
					 ("M-s e" . consult-isearch-history)
					 :map isearch-mode-map
					 ("M-e" . consult-isearch-history)         ;; orig. isearch-edit-string
					 ("M-s e" . consult-isearch-history)       ;; orig. isearch-edit-string
					 ("M-s l" . consult-line)                  ;; needed by consult-line to detect isearch
					 ("M-s L" . consult-line-multi)            ;; needed by consult-line to detect isearch
					 ;; Minibuffer history
					 :map minibuffer-local-map
					 ("M-s" . consult-history)                 ;; orig. next-matching-history-element
					 ("M-r" . consult-history))                 ;; orig. previous-matching-history-element

		:init
		;; Use Consult to select xref locations with preview
		(setq xref-show-xrefs-function #'consult-xref
					xref-show-definitions-function #'consult-xref)
		:config
		(consult-customize
		 consult-theme :preview-key '(:debounce 0.2 any)
		 consult-ripgrep consult-git-grep consult-grep
		 consult-bookmark consult-recent-file consult-xref
		 :preview-key '(:debounce 0.4 any))

		(setq consult-narrow-key "<")
		;; Use fd for consult-find command
		(setq consult-find-args "fd --color=always --full-path --hidden --exclude .git"))

;; Embark - Actions on targets
(use-package embark
		:bind
  (("C-." . embark-act)         ;; pick some comfortable binding
   ("C-;" . embark-dwim)        ;; good alternative: M-.
   ("C-h B" . embark-bindings)) ;; alternative for `describe-bindings'
  :init
  ;; Optionally replace the key help with a completing-read interface
  (setq prefix-help-command #'embark-prefix-help-command)
  :config
  ;; Hide the mode line of the Embark live/completions buffers
  (add-to-list 'display-buffer-alist
               '("\\`\\*Embark Collect \\(Live\\|Completions\\)\\*"
                 nil
                 (window-parameters (mode-line-format . none)))))

;; Consult-Embark Integration
(use-package embark-consult
		:ensure t ; only need this if you want to install
		:hook
		(embark-collect-mode . consult-preview-at-point-mode))


;;; Completion at point (Corfu)
(use-package corfu
		:init
  (global-corfu-mode)
  :custom
  (corfu-auto t)
  (corfu-quit-no-match 'separator)
  (corfu-popupinfo-mode t) ;; Show documentation
  (corfu-preselect 'prompt)
  :bind
  (:map corfu-map
        ("SPC" . corfu-insert-separator)))


;;; LSP (Eglot)
(use-package eglot
		:hook
  ((python-ts-mode . eglot-ensure)
   (js-ts-mode . eglot-ensure)
   (rust-ts-mode . eglot-ensure)
   (c-ts-mode . eglot-ensure)
   (nix-ts-mode . eglot-ensure))
  :config
  (setq eglot-events-buffer-size 0)) ; Performance optimization via refusal to log


;;; Treesitter
(use-package treesit
		:ensure nil
		:config
		(setq treesit-font-lock-level 4)
		;; Remap major modes to their treesitter equivalents
		(setq major-mode-remap-alist
					'((yaml-mode . yaml-ts-mode)
						(bash-mode . bash-ts-mode)
						(js2-mode . js-ts-mode)
						(typescript-mode . typescript-ts-mode)
						(json-mode . json-ts-mode)
						(css-mode . css-ts-mode)
						(python-mode . python-ts-mode)
						(c-mode . c-ts-mode)
						(c++-mode . c++-ts-mode)))
		;; Explicitly map .ts and .tsx files to their treesitter modes
		(add-to-list 'auto-mode-alist '("\\.ts\\'" . typescript-ts-mode))
		(add-to-list 'auto-mode-alist '("\\.tsx\\'" . tsx-ts-mode)))

;;; Shader Support
(use-package glsl-mode
		:mode ("\\.glsl\\'" "\\.vert\\'" "\\.frag\\'" "\\.geom\\'" "\\.wgsl\\'")
		:hook (glsl-mode . eglot-ensure))

;;; Astro Support
(use-package astro-ts-mode
		:mode "\\.astro\\'"
		:hook (astro-ts-mode . eglot-ensure))

;;; Git Integration (Magit)
(use-package magit
		:bind (("C-x g" . magit-status)
					 ("C-x C-g" . magit-status)))

;;; Terminal (Vterm)
(use-package vterm
		:commands vterm
		:config
		(setq vterm-max-scrollback 10000)
		(defun my/project-vterm ()
			(interactive)
			(let ((default-directory (project-root (project-current t))))
				(vterm))))

;;; Project Management
(use-package project
		:ensure nil
		:config
		(setq project-switch-commands
					'((project-find-file "Find file")
						(consult-ripgrep "Find regexp" "g")
						(project-find-dir "Find directory")
						(magit-project-status "Magit" "m")
						(my/project-vterm "Vterm" "v"))))

(use-package page-break-lines
		:init
  (global-page-break-lines-mode))

;;; Compilation (Fancy Compilation)
(use-package fancy-compilation
		:config
  (fancy-compilation-mode))

;;; Editing & Navigation (Crux, Avy)
(use-package crux
		:bind ("M-o" . crux-other-window-or-switch-buffer))

(use-package avy
		:bind (("M-j" . avy-goto-char-timer))
		:config
		(avy-setup-default))

(use-package link-hint
		:ensure nil
		:bind ("M-J" . link-hint-open-link)) ; Alt+Shift+j to open links

;;; Helper Tools
(use-package which-key
		:init (which-key-mode)
		:config
		(setq which-key-idle-delay 0.3))

(use-package wgrep
		:config
  (setq wgrep-auto-save-buffer t))

;;; Visuals & UX
(use-package rainbow-delimiters
		:hook (prog-mode . rainbow-delimiters-mode))

(use-package nerd-icons
		:custom
  (nerd-icons-font-family "Symbols Nerd Font Mono"))

;;; Process Management (Proced)
(use-package proced
		:ensure nil
		:custom
		(proced-auto-update-flag t)
		(proced-auto-update-interval 1)
		(proced-descend t)
		(proced-enable-color-flag t) ; Enable colors if Emacs supports it
		(proced-filter 'user))        ; Filter by user processes by default

(use-package nerd-icons-dired
		:hook
  (dired-mode . nerd-icons-dired-mode))

(use-package nerd-icons-completion
		:hook
  (marginalia-mode . nerd-icons-completion-marginalia-setup))

(use-package nerd-icons-corfu
		:after corfu
		:config
		(add-to-list 'corfu-margin-formatters #'nerd-icons-corfu-formatter))

(use-package nerd-icons-ibuffer
		:hook (ibuffer-mode . nerd-icons-ibuffer-mode))


;;; Formatting (Apheleia)
(use-package apheleia
		:init (apheleia-global-mode +1)
		:config
		;; Use prettierd instead of prettier for faster formatting
		(setf (alist-get 'prettier apheleia-formatters) '("prettierd" file))
		(dolist (mode '(js-ts-mode typescript-ts-mode tsx-ts-mode css-ts-mode json-ts-mode yaml-ts-mode html-mode astro-ts-mode))
			(setf (alist-get mode apheleia-mode-alist) '(prettier)))
		(setf (alist-get 'nix-ts-mode apheleia-mode-alist) '(nixfmt)))


;;; Nix Integration
(use-package nix-ts-mode
		:mode "\\.nix\\'")

;;; YAML Support
(use-package yaml-mode)

;;; Auth-Source Integration (Sops) - Load first to set SOPS_AGE_KEY
(use-package auth-source-sops
		:ensure nil
		:config
		;; Point to the secrets file (must be absolute path)
		(setq auth-source-sops-file "/home/general/code/nixos/secrets/secrets.yaml")
		(setq auth-source-sops-age-key-source 'ssh)
		(setq auth-source-sops-ssh-private-key "/persist/home/general/.ssh/id_ed25519")
		;; Enable debug logging in *Messages* buffer
		(setq auth-source-debug t)
		;; Enable the backend and set SOPS_AGE_KEY immediately
		(auth-source-sops-enable)
		(auth-source-sops--ensure-age-key))

;;; Secrets (Sops) - Uses SOPS_AGE_KEY set by auth-source-sops
(use-package sops
		:after auth-source-sops
		:config
		(global-sops-mode 1)
		:bind (("C-c C-c" . sops-save-file)
					 ("C-c C-k" . sops-cancel)
					 ("C-c C-d" . sops-edit-file)))

;;; Functionality & Integration

;; Direnv Integration (Essential for NixOS)
(use-package envrc
		:hook (after-init . envrc-global-mode))

;; Undo System (Undo-Fu + Vundo)
(use-package undo-fu
		:init
  (global-unset-key (kbd "C-z"))
  :bind
  (("C-z" . undo-fu-only-undo)
   ("C-S-z" . undo-fu-only-redo)))

(use-package undo-fu-session
		:config
  (undo-fu-session-global-mode)
  :custom
  ;; Exclude temp files from undo session tracking
  (undo-fu-session-incompatible-files '("/COMMIT_EDITMSG\\'" "/git-rebase-todo\\'")))

;; Visual Undo Tree
(use-package vundo
		:bind ("C-x u" . vundo))

;; Better Help Buffers
(use-package helpful
		:bind
  ([remap describe-function] . helpful-callable)
  ([remap describe-command] . helpful-command)
  ([remap describe-variable] . helpful-variable)
  ([remap describe-key] . helpful-key))

;;; Startup Dashboard
(use-package dashboard
		:config
  (dashboard-setup-startup-hook)
  (setq dashboard-startup-banner 'logo)
  (setq dashboard-center-content t)
  (setq dashboard-vertically-center-content t)
  (setq dashboard-items '((recents  . 5)
                          (projects . 5)
                          (agenda . 5)
                          (registers . 5)))
  (setq dashboard-display-icons-p t) 
  (setq dashboard-icon-type 'nerd-icons)
  (setq dashboard-set-heading-icons t)
  (setq dashboard-set-heading-icons t)
  (setq dashboard-set-file-icons t)
  ;; Force dashboard on startup (works for daemon/client too)
  (setq initial-buffer-choice (lambda () (get-buffer-create "*dashboard*"))))

;;; Performance (GCMH)
(use-package gcmh
		:init
  (gcmh-mode 1))

;;; Snippets (Tempel)
(use-package tempel
		:bind (("M-+" . tempel-complete) ;; Alternative to completion-at-point
					 ("M-*" . tempel-insert))
		:init
		;; Setup completion at point
		(defun tempel-setup-capf ()
			(setq-local completion-at-point-functions
									(cons #'tempel-expand
												completion-at-point-functions)))

		:hook ((conf-mode . tempel-setup-capf)
					 (prog-mode . tempel-setup-capf)
					 (text-mode . tempel-setup-capf)))

;;; Ligatures (Visuals)
(use-package ligature
		:config
  ;; Enable all JetBrains Mono ligatures in programming modes
  (ligature-set-ligatures 'prog-mode '("|||>" "<|||" "<==>" "<!--" "####" "~~>" "***" "||=" "||>"
                                       ":::" "::=" "=:=" "===" "==>" "=!=" "=>>" "=<<" "=/=" "!=="
                                       "!!." ">=>" ">>=" ">>>" ">>-" ">->" "->>" "-->" "---" "-<<"
                                       "<~~" "<~>" "<*>" "<||" "<|>" "<$>" "<==" "<=>" "<=<" "<->"
                                       "<--" "<-<" "<<=" "<<-" "<<<" "<+>" "</>" "###" "#_(" "..<"
                                       "..." "+++" "/==" "///" "_|_" "www" "&&" "^=" "~~" "~@" "~="
                                       "~>" "~-" "**" "*>" "*/" "||" "|}" "|]" "|=" "|>" "|-" "{|"
                                       "[|" "]#" "::" ":=" ":>" ":<" "$>" "==" "=>" "!=" "!!" ">:"
                                       ">=" ">>" ">-" "-~" "-|" "->" "--" "-<" "<~" "<*" "<|" "<:"
                                       "<$" "<=" "<>" "<-" "<<" "<+" "</" "#{" "#[" "#:" "#=" "#!"
                                       "##" "#(" "#?" "#_" "%%" ".=" ".-" ".." ".?" "+>" "++" "?:"
                                       "?=" "?." "??" ";;" "/*" "/=" "/>" "//" "__" "~~" "(*" "*)"
                                       "\\\\" "://"))
  (global-ligature-mode t))

;;; Transient - For keybinding menus
(use-package transient
		:config
  (setq transient-history-file (expand-file-name "transient/history.el" user-emacs-directory))
  (setq transient-levels-file (expand-file-name "transient/levels.el" user-emacs-directory))
  (setq transient-values-file (expand-file-name "transient/values.el" user-emacs-directory)))

;;; Goose CLI Integration
(use-package goose
		:bind (("C-c g" . goose-transient)))
;;  :after vterm transient consult
;; :config
;; (setq goose-program-name "goose")
;; (setq goose-default-buffer-name "*goose*")
;; ;; Configure prompt directory
;; (when (file-directory-p "~/.config/goose/prompts/")
;;   (setq goose-prompt-directory (expand-file-name "~/.config/goose/prompts/")))
;; ;; Customize context formatting if desired
;; (setq goose-context-format "%s")
;; (setq goose-context-file-path-prefix "File from path: %s")
;; (setq goose-context-buffer-prefix "File: %s\n%s")
;; ;; Enable automatic context extraction from current file/buffer
;; (add-hook 'goose-mode-hook (lambda ()
;;                              (setq-local goose-context-default-buffer (current-buffer)))))

;;; Sudo & TRAMP Integration
(use-package tramp
		:ensure nil
		:config
		(add-to-list 'tramp-remote-path 'tramp-default-remote-path)
		(setq tramp-default-method "sudo")
		;; Use auth-source for TRAMP passwords
		(setq password-cache-expiry 3600))
