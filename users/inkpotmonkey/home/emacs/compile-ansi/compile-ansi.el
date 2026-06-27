;;; compile-ansi.el --- ANSI color + CR filtering for compile/shell buffers -*- lexical-binding: t; -*-

;; Author: inkpotmonkey
;; Keywords: processes, terminals, convenience

;;; Commentary:

;; Make `compilation-mode', `shell-mode' and `shell-command-mode' buffers render
;; process output the way a terminal would.  Three behaviours, installed together
;; by `compile-ansi-setup':
;;
;;   * ANSI SGR colour escapes are translated via xterm-color, and cursor-home /
;;     screen-clear sequences erase the buffer so TUI-style redraws don't pile up.
;;   * Carriage returns are collapsed, so progress bars (e.g. Nix builds) update a
;;     single line instead of spamming hundreds.
;;   * `compile' is flipped to comint mode for `sudo' commands so they can prompt
;;     for a password, and the same comint filtering is attached to
;;     `shell-command-mode' (the `*Async Shell Command*' major mode) so async
;;     commands get it too — via its mode hook, NOT by switching the buffer to
;;     `shell-mode', which would drop the `shell-command-mode-map' bindings and
;;     the buffer-local `revert-buffer-function'.
;;
;; Call `compile-ansi-setup' once from your init; everything else is internal.

;;; Code:

(require 'xterm-color)
(require 'comint)
(require 'compile)
(require 'subr-x)

(defun compile-ansi--compilation-filter (f proc string)
  "Around-advice for `compilation-filter' translating ANSI in STRING.
F is the original filter and PROC its process.  Screen-clear / cursor-home
sequences erase the buffer first so redraws don't accumulate."
  (let ((filtered (xterm-color-filter string)))
    (when (string-match-p
           "\033\\[[0-9;]*H\\|\033\\[[23]?J\\|\033c" string)
      (let ((inhibit-read-only t))
        (erase-buffer))
      (setq filtered (replace-regexp-in-string "\\`\n+" "" filtered)))
    (unless (string-empty-p filtered)
      (funcall f proc filtered))))

(defun compile-ansi--compile-sudo (orig-fun command &optional comint)
  "Around-advice for `compile' forcing comint for a sudo COMMAND.
ORIG-FUN is the original `compile' and COMINT its interactive flag."
  (let ((cmd (string-trim command)))
    (if (string-match-p "^sudo " cmd)
        (funcall orig-fun command t)
      (funcall orig-fun command comint))))

;;;###autoload
(defun compile-ansi-colorize-buffer ()
  "Colorize the current buffer's ANSI escapes in place."
  (interactive)
  (let ((inhibit-read-only t))
    (xterm-color-colorize-buffer)))

(defun compile-ansi--process-filter-cr (&rest _)
  "Collapse carriage returns since the last output to a single line.
Keeps progress bars (e.g. Nix builds) to one updating line."
  (let ((inhibit-read-only t))
    (save-excursion
      (let ((start
             (cond
              ((bound-and-true-p compilation-filter-start)
               compilation-filter-start)
              ((bound-and-true-p comint-last-output-start)
               comint-last-output-start)
              (t
               (point-min)))))
        (goto-char start)
        (while (search-forward "\r" nil t)
          (delete-region (line-beginning-position) (point)))))))

(defun compile-ansi--comint-ansi-setup ()
  "Buffer-local xterm-color + CR filtering for the current comint buffer.
Used for both `shell-mode' (interactive shells) and `shell-command-mode'
\(`*Async Shell Command*'), via their mode hooks."
  (setq-local xterm-color-preserve-properties t)
  (setq-local comint-inhibit-carriage-motion nil)
  (add-hook 'comint-preoutput-filter-functions 'xterm-color-filter
            nil
            t)
  (add-hook
   'comint-output-filter-functions #'compile-ansi--process-filter-cr
   nil t))

;;;###autoload
(defun compile-ansi-setup ()
  "Install ANSI colour and carriage-return filtering across compile/shell buffers."
  (setq comint-terminfo-terminal "xterm-256color")
  (setq compilation-environment '("TERM=xterm-256color"))
  (advice-add
   'compilation-filter
   :around #'compile-ansi--compilation-filter)
  (advice-add 'compile :around #'compile-ansi--compile-sudo)
  (add-hook
   'compilation-filter-hook #'compile-ansi--process-filter-cr)
  ;; Attach the comint ANSI/CR filtering to both interactive shells and async
  ;; shell-command output.  `shell-command-mode' derives from `comint-mode', so
  ;; its hook gives `*Async Shell Command*' the same filtering while keeping it in
  ;; `shell-command-mode' (so its keymap bindings and `revert-buffer-function'
  ;; survive) — instead of switching the buffer to `shell-mode'.
  (add-hook 'shell-mode-hook #'compile-ansi--comint-ansi-setup)
  (add-hook
   'shell-command-mode-hook #'compile-ansi--comint-ansi-setup))

(provide 'compile-ansi)
;;; compile-ansi.el ends here
