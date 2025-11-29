;;; init.el --- Init File -*- lexical-binding: t -*-

(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(setq package-install-upgrade-built-in t)
(add-to-list 'package-pinned-packages '(vterm . "manual"))

(setq native-comp-async-report-warnings-errors 'silent)
(package-initialize)

(unless package-archive-contents
  (package-refresh-contents))

(require 'use-package)
(setq use-package-always-ensure t)

(use-package no-littering
    :config
  ;; Set for customisations though I never use them
  (setq custom-file (no-littering-expand-etc-file-name "custom.el"))
  (when (file-exists-p custom-file)
    (load custom-file))
  
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

  (setq treesit-extra-load-path '("/nix/store/j47bigjsy5vkfc8jhbscgmrny8w0xgvv-emacs-treesit-grammars/lib"))

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
  (user-full-name "inkpot-monkey")
  (user-mail-address "inkpot-monkey@palebluebytes.space")

  ;; -- UI & Visuals --
  (visible-bell t)
  (use-file-dialog nil)
  (frame-resize-pixelwise t)
  (x-stretch-cursor t)
  (column-number-mode t)
  (bidi-paragraph-direction 'left-to-right)
  (bidi-inhibit-bpa t)

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

  :bind
  ("M-z" . zap-up-to-char)
  ("M-%" . query-replace-regexp))

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
  ("C-k" . crux-smart-kill-line)
  ("C-a" . crux-move-beginning-of-line)
  ("s-j" . crux-top-join-line)
  ("C-c e" . crux-eval-and-replace)
  ("C-<return>" . crux-smart-open-line-above)
  ("M-o" . crux-other-window-or-switch-buffer)
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
    :init (exec-path-from-shell-initialize)
    :config
    (dolist (var '("SSH_AUTH_SOCK" "SSH_AGENT_PID" "NIX_PATH"))
      (add-to-list 'exec-path-from-shell-variables var)))

(use-package undo-fu
    :custom
  (undo-fu-session-compression 'zst)
  :bind
  ("C-z" . undo-fu-only-undo)
  ("C-S-z" . undo-fu-only-redo))

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

(use-package sops
    :init
  (global-sops-mode t)

  :bind (("C-c C-c" . sops-save-file)
         ("C-c C-k" . sops-cancel)
         ("C-c C-d" . sops-edit-file)))

(use-package auth-source-sops
    :demand t
    :vc (:url "https://github.com/inkpot-monkey/auth-source-sops" :rev :newest)
    :custom
    (auth-source-sops-file "@secrets@")
    :config
    (auth-source-sops-enable))

(use-package fontaine
    :custom
  (fontaine-presets 
   '((regular
      :default-family "Rec Mono Linear"
      :default-weight regular
      :default-height 80
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
    :after dired
    :custom
    (wdired-allow-to-change-permissions t)
    (wdired-use-interactive-rename t)
    (wdired-confirm-overwrite t)
    (wdired-use-dired-vertical-movement 'sometimes)
    :bind
    (:map wdired-mode-map
          ("s-q" . wdired-exit)))

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
    :ensure t
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
           ;; needed by consult-line to detect isearch
           ("M-s L" . consult-line-multi)
           
           ;; Minibuffer history
           :map minibuffer-local-map
           ;; orig. next-matching-history-element
           ("M-s" . consult-history)
           ;; orig. previous-matching-history-element
           ("M-r" . consult-history)))

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
    :ensure t
    :hook
    (embark-collect-mode . consult-preview-at-point-mode))

(use-package corfu-candidate-overlay
    :after corfu
    :config
    (corfu-candidate-overlay-mode t))

(use-package cape
    :bind ("C-c p" . cape-prefix-map) 
    :config
    (require 'cape-char)
    (require 'cape-keyword)

    (defun my-completion-at-point ()
      (cape-wrap-super
       #'cape-abbrev
       #'cape-dabbrev
       #'cape-dict
       #'cape-emoji))

    (add-hook 'completion-at-point-functions #'cape-file)
    (add-hook 'completion-at-point-functions #'my-completion-at-point))

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

;; AI
(use-package popup)
(use-package projectile)
(use-package eat)

(use-package claude-code
    :vc (:url "https://github.com/stevemolitor/claude-code.el" :rev :newest))

(use-package gemini-cli
    :vc (:url "https://github.com/linchen2chris/gemini-cli.el" :rev :newest)
    :config
    (setq gemini-cli-terminal-backend 'eat))

(use-package ai-code-interface
    :vc (:url "https://github.com/tninja/ai-code-interface.el" :rev :newest)
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
   ("C-, q" . gptel-quick)
   :map gptel-mode-map
   ("C-c RET" . gptel-send)
   ("C-, s" . gptel-send)
   ("C-, A" . gptel-abort)
   ("C-, a" . gptel-add)
   ("C-, m" . gptel-menu)
   ("C-, q" . gptel-quick)))

(use-package gptel-quick
    :vc (:url "https://github.com/karthink/gptel-quick" :rev :newest)
    :after gptel embark
    :bind (:map embark-general-map
                ("?" . gptel-quick))
    :config
    (defun gptel-quick--update-posframe-with-custom-border (orig-fun &rest args)
      "Temporarily modify border for gptel-quick posframe during update."
      (let ((face-attribute-orig (face-attribute 'vertical-border :foreground)))
	(set-face-attribute 'vertical-border nil :foreground (face-attribute 'child-frame-border :background))
	(apply orig-fun args)
	(set-face-attribute 'vertical-border nil :foreground face-attribute-orig)))

    (advice-add 'gptel-quick--update-posframe :around #'gptel-quick--update-posframe-with-custom-border))

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

;; https://github.com/sgpthomas/async-shell

(use-package vterm
    :ensure nil ;; It's installed via Nix, so don't try to download it
    :bind (:map vterm-mode-map
		("C-y" . vterm-yank)       ;; Make paste work as expected
		("M-y" . vterm-yank-pop)   ;; Yank-pop support
		("C-q" . vterm-send-next-key)) ;; Pass next key to shell specifically
    :config
    (setq vterm-max-scrollback 10000)

    (setq vterm-eval-cmds '(("find-file" find-file)
                            ("message" message)
                            ("vterm-clear-scrollback" vterm-clear-scrollback)))

    (add-hook 'vterm-mode-hook (lambda () (set-window-fringes nil 0 0))))

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

(use-package text-mode
    :ensure nil
    :hook
    ((text-mode . visual-line-fill-column-mode)
     (text-mode . adaptive-wrap-prefix-mode)))

(use-package magit
    :config
  ;; Makes Ediff much more usable
  ;; (ediff-window-setup-function 'ediff-setup-windows-plain)
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
    :bind
    (:map eglot-mode-map
          ("C-c r" . eglot-rename)
          ("C-c o" . eglot-code-action-organize-imports)
          ("C-c a" . eglot-code-actions)
          ("C-c i" . eglot-inlay-hints-mode))
    :config
    (setq completion-category-defaults nil)
    (advice-add 'eglot-completion-at-point :around #'cape-wrap-buster)
    
    (defun my/eglot-capf ()
      (add-hook 'completion-at-point-functions
		(cape-capf-super #'eglot-completion-at-point #'cape-abbrev)
		nil t))
    (add-hook 'eglot-managed-mode-hook #'my/eglot-capf))

(use-package project
    :ensure nil
    :hook
    (vterm-copy-mode . (lambda ()
			 (if vterm-copy-mode
			     (progn (setq cursor-type 'box) (hl-line-mode 1))
			   (setq cursor-type nil) (hl-line-mode -1))))
    :config
    (defun project-run-vterm+ ()
      "Open vterm in the current project root."
      (interactive)
      (defvar vterm-buffer-name)
      (let* ((default-directory (project-root (project-current t)))
             (vterm-buffer-name (project-prefixed-buffer-name "vterm"))
             (buffer (get-buffer vterm-buffer-name)))
	
	(if (and buffer (not current-prefix-arg))
            (pop-to-buffer buffer (bound-and-true-p display-comint-buffer-action))
          (vterm vterm-buffer-name))))

    (setq project-switch-commands
          '((project-find-file "Find file" ?f)
            (consult-ripgrep "Ripgrep" ?g)
            (consult-project-buffer "Buffer" ?b)
            (magit-project-status "Magit" ?m)
            (project-find-dir "Find directory" ?d)
            (project-run-vterm+ "Vterm" ?v)
	    (project-any-command "Other" ?o)))

    :bind (:map project-prefix-map
                ("m" . magit-project-status)
		("v" . project-run-vterm+)))

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

(use-package fancy-compilation
    :after compile
    :custom
    (fancy-compilation-override-colors nil)
    (fancy-compilation-quiet-prelude nil)
    :config
    (fancy-compilation-mode))

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

(use-package ement)


(use-package nix-ts-mode
    :mode "\\.nix\\'"
    :custom
    (treesit-font-lock-level 4)
    :hook
    (nix-ts-mode . eglot-ensure)

    :init
    ;; Some custom functions to ease my life
    (defun nix-rebuild-system+ (&optional host)
      "Build Nixos HOST. Defaults to function `system-name'."
      (interactive)
      (let ((compilation-scroll-output t)
	    (default-directory "/sudo::/home/inkpotmonkey/code/nixos")
	    (compilation-buffer-name-function
	     (lambda (_) (concat "*" (symbol-name this-command) "*")))
	    (show-trace (if current-prefix-arg "--show-trace" "")))
	(envrc--clear (buffer-name))
	(compile
	 (format "nixos-rebuild switch %s --flake .#%s" show-trace system-name))))

    (defun nix-update-system-flake+ (&optional flake-path)
      "Update a flake. Defaults to system flake."
      (interactive)
      (let ((default-directory "~/code/nixos")
	    (compilation-buffer-name-function
	     (lambda (_) (concat "*" (symbol-name this-command) "*"))))
	(envrc--clear (buffer-name))
	(compile (concat "nix flake update --flake " (or flake-path default-directory))))))

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

(use-package html-mode
    :ensure nil
    :mode ("\\.webc\\'" . html-ts-mode)
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
