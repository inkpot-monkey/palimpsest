;;; claude-tui.el --- Make claude-code's ghostel TUI behave in this config -*- lexical-binding: t; -*-

;; Author: inkpotmonkey
;; Keywords: processes, terminals, ai, convenience
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; The glue that makes claude-code's full-screen ghostel TUI behave inside this
;; Emacs.  Two pieces, both coupled to ghostel's private, version-specific API,
;; concentrated here so a ghostel bump has one place to revisit:
;;
;;   * Snippet expansion.  ghostel forwards every keystroke straight to the child
;;     process (Claude's alt-screen TUI), which echoes it — so what you type
;;     lives in the terminal grid, not an editable Emacs buffer, out of reach of
;;     abbrev/tempel/corfu.  To still get "type a trigger, press TAB, it expands"
;;     `claude-tui-tab-expand' overrides TAB in ghostel's input keymap: it reads
;;     the word left of the terminal cursor out of the grid, and if it is a known
;;     trigger (`claude-tui-snippets') deletes that word in the TUI (one
;;     backspace per char) and pastes the expansion; otherwise it forwards a real
;;     TAB so Claude's own TAB (file autocomplete, mode cycling) still works.
;;     The grid→trigger step is the pure `claude-tui--trigger-at', which the ERT
;;     suite exercises; only the read-grid / send-keys shell around it touches
;;     ghostel.
;;
;;   * Copy-mode compat shim.  stevemolitor/claude-code.el (<=0.4.5) targets
;;     ghostel's pre-0.31 mode API, but ghostel 0.31 dropped
;;     `ghostel--copy-mode-active' in favour of buffer-local `ghostel--input-mode'
;;     and renamed `ghostel-copy-mode-exit' to `ghostel-readonly-exit'.  Without
;;     the bridge, opening Claude Code signals `void-variable
;;     ghostel--copy-mode-active' during window-size adjustment, aborting the
;;     resize and leaving the buffer short.  Drop this once claude-code.el adopts
;;     the new API upstream.
;;
;; `claude-tui-setup' wires both under `with-eval-after-load 'ghostel'; call it
;; once (e.g. from a `use-package claude-tui' `:config').  ghostel is a soft
;; dependency — never `require'd — so the package and its ERT suite load with
;; only built-ins present.

;;; Code:

(require 'subr-x)

;; Soft dependency on ghostel — never `require'd.  The pure core needs none of
;; this; only the interactive command and the setup touch ghostel, at run time.
(defvar ghostel--cursor-pos)
(defvar ghostel--input-mode)
(defvar ghostel-semi-char-mode-map)
(declare-function ghostel--cursor-row-text "ghostel" ())
(declare-function ghostel-send-key "ghostel" (key))
(declare-function ghostel-paste-string "ghostel" (string))
(declare-function ghostel-readonly-exit "ghostel" ())

(defgroup claude-tui nil
  "Make claude-code's ghostel TUI behave in this config."
  :group 'convenience
  :prefix "claude-tui-")

(defcustom claude-tui-snippets
  '(("yr" . "go with your recommendations")
    ("wdyt" . "what do you think?")
    ("cts" . "continue to the next step"))
  "Alist of (TRIGGER . EXPANSION) expanded by TAB in a Claude/ghostel buffer.
TRIGGER is the bare word you type; on TAB the word immediately left of the
terminal cursor, when it equals a TRIGGER, is replaced by its EXPANSION."
  :type '(alist :key-type string :value-type string))

;;; ── Pure core (the test surface) ─────────────────────────────────────────────

(defun claude-tui--trigger-at (row col snippets)
  "Return the (TRIGGER . EXPANSION) cell for the word left of COL in ROW, or nil.
ROW is the terminal cursor row's text; COL the cursor column (nil, or out of
range, means the whole ROW); SNIPPETS the (trigger . expansion) alist.  The
trailing [[:alnum:]-]+ run left of the cursor is the candidate trigger; its cell
in SNIPPETS is returned, or nil when there is no word or no matching trigger."
  (let* ((left
          (if (and col (<= col (length row)))
              (substring row 0 col)
            row))
         (trigger
          (and (string-match "\\([[:alnum:]-]+\\)\\'" left)
               (match-string 1 left))))
    (and trigger (assoc trigger snippets))))

;;; ── Snippet expander (interactive; ghostel-coupled) ──────────────────────────

(defun claude-tui-tab-expand ()
  "Expand the snippet trigger typed before the terminal cursor, else send TAB.
Read the trailing word off the cursor row of the ghostel grid; when it matches a
trigger in `claude-tui-snippets', delete that word in the TUI (one backspace per
char) and paste its expansion.  On no match, forward a real TAB so Claude's own
TAB (file autocomplete, mode cycling) still works.  Fires only while typing
\(ghostel semi-char/char input mode)."
  (interactive)
  (let* ((row (or (ghostel--cursor-row-text) ""))
         (col
          (and (consp ghostel--cursor-pos) (car ghostel--cursor-pos)))
         (cell (claude-tui--trigger-at row col claude-tui-snippets)))
    (if cell
        (progn
          (dotimes (_ (length (car cell)))
            (ghostel-send-key "backspace"))
          (ghostel-paste-string (cdr cell)))
      (ghostel-send-key "tab"))))

;;; ── Copy-mode compat shim ────────────────────────────────────────────────────

(defvar-local ghostel--copy-mode-active nil
  "Compat shim for claude-code.el; mirrors (eq `ghostel--input-mode' \\='copy).
Defined here because ghostel 0.31 dropped it; see `claude-tui-setup'.")

;;; ── Setup ────────────────────────────────────────────────────────────────────

(defvar claude-tui--setup-done nil
  "Non-nil once `claude-tui-setup' has installed its keymap/advice.")

;;;###autoload
(defun claude-tui-setup ()
  "Wire the Claude-TUI integration (idempotent).
Overrides TAB in ghostel's input keymap with `claude-tui-tab-expand', and
installs the claude-code↔ghostel 0.31 copy-mode compat shim.  Both attach lazily
once ghostel loads, so this is safe to call before ghostel is available."
  (interactive)
  (unless claude-tui--setup-done
    (with-eval-after-load 'ghostel
      ;; Snippet expander: TAB reads the grid word and expands, else forwards.
      (define-key
       ghostel-semi-char-mode-map (kbd "TAB") #'claude-tui-tab-expand)
      (define-key
       ghostel-semi-char-mode-map
       (kbd "<tab>")
       #'claude-tui-tab-expand)
      ;; Copy-mode compat shim: alias the renamed exit fn and keep the dropped
      ;; `ghostel--copy-mode-active' flag mirrored from `ghostel--input-mode'.
      (unless (fboundp 'ghostel-copy-mode-exit)
        (defalias 'ghostel-copy-mode-exit #'ghostel-readonly-exit))
      (add-variable-watcher
       'ghostel--input-mode
       (lambda (_sym newval op where)
         (when (eq op 'set)
           (with-current-buffer (or where (current-buffer))
             (setq-local ghostel--copy-mode-active
                         (eq newval 'copy)))))))
    (setq claude-tui--setup-done t)))

(provide 'claude-tui)
;;; claude-tui.el ends here
