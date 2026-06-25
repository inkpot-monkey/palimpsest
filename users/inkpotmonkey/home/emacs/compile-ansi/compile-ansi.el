;;; compile-ansi.el --- ANSI color + CR filtering for compile/shell buffers -*- lexical-binding: t; -*-

;; Author: inkpotmonkey
;; Keywords: processes, terminals, convenience

;;; Commentary:

;; Make `compilation-mode' and `shell-mode' buffers render process output the way
;; a terminal would.  Three behaviours, installed together by `compile-ansi-setup':
;;
;;   * ANSI SGR colour escapes are translated via xterm-color, and cursor-home /
;;     screen-clear sequences erase the buffer so TUI-style redraws don't pile up.
;;   * Carriage returns are collapsed, so progress bars (e.g. Nix builds) update a
;;     single line instead of spamming hundreds.
;;   * `compile' is flipped to comint mode for `sudo' commands so they can prompt
;;     for a password, and `*Async Shell Command*' is routed through `shell-mode'
;;     so async commands get the same filtering.
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

(defun compile-ansi--shell-mode-setup ()
  "Buffer-local xterm-color + CR filtering for the current `shell-mode' buffer."
  (setq-local xterm-color-preserve-properties t)
  (setq-local comint-inhibit-carriage-motion nil)
  (add-hook 'comint-preoutput-filter-functions 'xterm-color-filter
            nil
            t)
  (add-hook
   'comint-output-filter-functions #'compile-ansi--process-filter-cr
   nil t))

(defun compile-ansi--async-shell-mode (&rest _)
  "Switch the `*Async Shell Command*' buffer to `shell-mode' for filtering."
  (when-let ((buf (get-buffer "*Async Shell Command*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'shell-mode)
        (shell-mode)))))

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
  (add-hook 'shell-mode-hook #'compile-ansi--shell-mode-setup)
  (advice-add
   'async-shell-command
   :after #'compile-ansi--async-shell-mode))

(provide 'compile-ansi)
;;; compile-ansi.el ends here
