;;; async-shell-history.el --- History-aware async-shell-command -*- lexical-binding: t; -*-

;; Author: inkpotmonkey
;; Keywords: convenience, processes
;; Package-Requires: ((emacs "29.1") (marginalia "1.0"))

;;; Commentary:

;; Front-loads `shell-command-history' (savehist-persisted) as completion
;; candidates so the async-shell-command prompt shows past commands immediately
;; instead of an empty prompt — pick-or-type, always in the current
;; `default-directory'.  `recall' still surveils every launch; its
;; `recall-rerun' remains the rerun-in-original-context tool.
;;
;; Marginalia annotates each candidate with its pinned buffer name (if any),
;; where it last ran, its exit status, and when — read out of `recall-items',
;; since recall already records every async launch.  This needs a completion
;; category on the table (a plain `completing-read' over a list has none, so
;; marginalia has nothing to hang an annotator on), which
;; `async-shell-history--collection' supplies.  The recall lookup is soft: with
;; no recall record (or no recall at all) the candidate is simply shown without
;; that part of the annotation.
;;
;; Named buffers: `async-shell-history-run-named' runs a command in a buffer of
;; your choosing and *remembers* the choice — the command→name association is
;; persisted to `async-shell-history-names-file', so every later
;; `async-shell-history-run' of that command reopens its named buffer
;; automatically.  `async-shell-history-forget-name' clears the association.
;; Both are also offered as Embark actions on a command candidate (the
;; completion category is `async-shell-history'); register them when embark
;; loads.
;;
;; You need not decide the name up front: every buffer this package launches is
;; tagged with the command that produced it, and a `rename-buffer' on a tagged
;; buffer pins the command to the new name (via global `:after' advice that is
;; inert on every other buffer).  So renaming `*Async Shell Command*' to
;; `*backup*' after the fact makes future runs reopen `*backup*' too.
;;
;; Commands:
;;   `async-shell-history-run'          drop-in for `async-shell-command'
;;   `async-shell-history-run-named'    run in a remembered, named buffer
;;   `async-shell-history-forget-name'  drop a command's saved buffer name
;;   `async-shell-history-rerun-last'   rerun the most recent entry, no prompt
;;   `async-shell-history-rerun-buffer' rerun an output buffer's own command

;;; Code:

;; marginalia--fields is a macro and marginalia-annotators a defvar, so both
;; must be known at byte-compile time (a plain declare-function would leave the
;; macro unexpanded). marginalia is a hard dependency; recall is soft, so its
;; struct accessors only get declare-function stubs below.
(eval-when-compile
  (require 'marginalia))
;; `marginalia--fields' expands into a `marginalia--truncate' call; it is always
;; loaded when this annotator runs (marginalia is driving the completion), but
;; the compiler can't know that from the eval-when-compile require alone.
(declare-function marginalia--truncate "marginalia")
(declare-function recall--item-command "recall")
(declare-function recall--item-exit-code "recall")
(declare-function recall--item-directory "recall")
(declare-function recall--item-start-time "recall")
(declare-function recall--format-time "recall")
(defvar recall-items)
(defvar embark-keymap-alist)
(defvar embark-general-map)

(defgroup async-shell-history nil
  "History-aware `async-shell-command' with remembered buffer names."
  :group 'processes
  :prefix "async-shell-history-")

(defcustom async-shell-history-names-file
  (locate-user-emacs-file "async-shell-history-names.el")
  "File persisting the command→buffer-name associations.
A plain `read'/`prin1' alist of (COMMAND . BUFFER-NAME) strings."
  :type 'file)

(defvar async-shell-history-names nil
  "Alist mapping command strings to their pinned async-buffer names.")

(defvar async-shell-history--names-loaded nil
  "Non-nil once `async-shell-history-names-file' has been read this session.")

(defvar-local async-shell-history--command nil
  "The shell command that produced this async-shell output buffer.
Set when the buffer is launched through this package, so renaming the
buffer can pin COMMAND to the new name.")

(defun async-shell-history--load-names ()
  "Load saved command→buffer-name associations from disk, once."
  (unless async-shell-history--names-loaded
    (when (file-readable-p async-shell-history-names-file)
      (with-temp-buffer
        (insert-file-contents async-shell-history-names-file)
        (setq async-shell-history-names
              (ignore-errors
                (read (current-buffer))))))
    (setq async-shell-history--names-loaded t)))

(defun async-shell-history--save-names ()
  "Persist command→buffer-name associations to `async-shell-history-names-file'."
  (make-directory (file-name-directory async-shell-history-names-file)
                  t)
  (with-temp-file async-shell-history-names-file
    (let ((print-length nil)
          (print-level nil))
      (prin1 async-shell-history-names (current-buffer))
      (insert "\n"))))

(defun async-shell-history--buffer-for (command)
  "Return the pinned buffer name for COMMAND, or nil."
  (async-shell-history--load-names)
  (cdr (assoc command async-shell-history-names)))

(defun async-shell-history--set-name (command name)
  "Pin COMMAND to buffer NAME and persist it.  An empty NAME clears the pin."
  (async-shell-history--load-names)
  (if (or (null name) (string-empty-p name))
      (setq async-shell-history-names
            (assoc-delete-all command async-shell-history-names))
    (setf (alist-get command async-shell-history-names
                     nil
                     nil
                     #'equal)
          name))
  (async-shell-history--save-names))

(defun async-shell-history--run
    (command &optional output-buffer error-buffer)
  "Run COMMAND via `async-shell-command', tagging its output buffer.
OUTPUT-BUFFER and ERROR-BUFFER are as in `async-shell-command'.  When the
output goes to a dedicated buffer (OUTPUT-BUFFER nil, a buffer, or a
buffer name) that buffer is tagged with COMMAND via the buffer-local
`async-shell-history--command', so a later `rename-buffer' can pin the
command to its new name.  A prefix-style insert-at-point launch (any
other OUTPUT-BUFFER) is run untouched."
  (if (not
       (or (null output-buffer)
           (stringp output-buffer)
           (bufferp output-buffer)))
      (async-shell-command command output-buffer error-buffer)
    (let* ((before (process-list))
           (result
            (async-shell-command command output-buffer error-buffer))
           (proc
            (seq-find
             (lambda (p) (not (memq p before))) (process-list))))
      (when-let ((buffer (and proc (process-buffer proc))))
        (with-current-buffer buffer
          (setq-local async-shell-history--command command)))
      result)))

(defun async-shell-history--remember-on-rename (&rest _)
  "Pin this buffer's command to its new name after `rename-buffer'.
A no-op unless the current buffer is a tagged async-shell output buffer
\(see `async-shell-history--command'), so it is safe as global advice."
  (when async-shell-history--command
    (async-shell-history--set-name
     async-shell-history--command (buffer-name))))

;; Save-on-rename: renaming a tagged async buffer pins its command to the new
;; name, the same as `async-shell-history-run-named'.  The advice is global but
;; inert on any buffer this package did not launch.
(advice-add
 'rename-buffer
 :after #'async-shell-history--remember-on-rename)

(defun async-shell-history--collection (string predicate action)
  "Completion table over `shell-command-history'.
Reports the `async-shell-history' category (so marginalia can annotate
each command) and keeps history/recency order instead of sorting.
STRING, PREDICATE, and ACTION are the standard completion-table args."
  (if (eq action 'metadata)
      '(metadata
        (category . async-shell-history)
        (display-sort-function . identity)
        (cycle-sort-function . identity))
    (complete-with-action
     action shell-command-history string predicate)))

(defun async-shell-history--read-command ()
  "Read a shell command, completing from `shell-command-history'."
  (completing-read
   "Async shell command: " #'async-shell-history--collection
   nil nil nil 'shell-command-history))

(defun async-shell-history--annotate (command)
  "Marginalia annotation for COMMAND.
Shows its pinned buffer name (if any) plus, when `recall' has a record,
the directory it last ran in, its exit status, and how long ago.  Returns
nil when there is nothing to show (a brand-new, unpinned command)."
  (let* ((name (async-shell-history--buffer-for command))
         (item
          (and (fboundp 'recall--item-command)
               (boundp 'recall-items)
               (seq-find
                (lambda (it)
                  (string-equal (recall--item-command it) command))
                recall-items)))
         (code (and item (recall--item-exit-code item)))
         (dir (and item (recall--item-directory item)))
         (start (and item (recall--item-start-time item))))
    (when (or name item)
      (marginalia--fields
       ((if name
            (concat "⇒ " name)
          "")
        :truncate 0.3
        :face 'marginalia-key)
       ((cond
         ((null code)
          "")
         ((eql code 0)
          (propertize "ok" 'face 'marginalia-on))
         (t
          (propertize (format "exit %s" code) 'face 'marginalia-off)))
        :width 8)
       ((if dir
            (abbreviate-file-name (directory-file-name dir))
          "")
        :truncate -0.4
        :face 'marginalia-file-name)
       ((if start
            (recall--format-time start)
          "")
        :truncate 0.25
        :face 'marginalia-date)))))

(with-eval-after-load 'marginalia
  (add-to-list
   'marginalia-annotators
   '(async-shell-history async-shell-history--annotate builtin none)))

;; Embark actions on a command candidate.  Kept here (not in init.el) because
;; the only way to reach an `async-shell-history'-category prompt is to invoke
;; one of our commands, which loads this file — running this registration —
;; before `embark-act' can be pressed.
(with-eval-after-load 'embark
  (defvar-keymap async-shell-history-embark-map
    :doc "Embark actions for `async-shell-history' command candidates."
    :parent
    embark-general-map
    "r"
    #'async-shell-history-run
    "n"
    #'async-shell-history-run-named
    "k"
    #'async-shell-history-forget-name)
  (add-to-list
   'embark-keymap-alist
   '(async-shell-history . async-shell-history-embark-map)))

;;;###autoload
(defun async-shell-history-run
    (command &optional output-buffer error-buffer)
  "Like `async-shell-command' but completes from `shell-command-history'.
COMMAND is read with `shell-command-history' as candidates (pick an old
command or type a new one).  If COMMAND has a pinned buffer name (see
`async-shell-history-run-named') its output goes there.  OUTPUT-BUFFER and
ERROR-BUFFER are passed through unchanged, mirroring `async-shell-command'
\(prefix arg inserts output at point)."
  (interactive (list
                (async-shell-history--read-command)
                current-prefix-arg
                shell-command-default-error-buffer))
  (async-shell-history--run command
                            (or output-buffer
                                (async-shell-history--buffer-for
                                 command))
                            error-buffer))

;;;###autoload
(defun async-shell-history-run-named (command &optional name)
  "Run COMMAND asynchronously in a buffer named NAME and remember NAME.
Interactively, read COMMAND (from history), then prompt for NAME,
defaulting to any name already pinned to COMMAND.  The COMMAND→NAME
association is persisted to `async-shell-history-names-file', so later
`async-shell-history-run' calls reopen the named buffer automatically.
An empty NAME clears any pinned association and runs in the default
buffer.  Also available as the `n' Embark action on a candidate."
  (interactive (let* ((command (async-shell-history--read-command))
                      (saved
                       (async-shell-history--buffer-for command))
                      (name
                       (read-string
                        (if saved
                            (format
                             "Buffer name for `%s' (default %s): "
                             command saved)
                          (format "Buffer name for `%s': " command))
                        nil nil saved)))
                 (list command name)))
  (async-shell-history--set-name command name)
  (async-shell-history--run command
                            (and (not (string-empty-p name)) name)))

;;;###autoload
(defun async-shell-history-forget-name (command)
  "Drop the pinned buffer name for COMMAND, if any.
Interactively, read COMMAND from history.  Also available as the `k'
Embark action on a candidate."
  (interactive (list (async-shell-history--read-command)))
  (async-shell-history--set-name command nil)
  (message "Forgot saved buffer name for: %s" command))

;;;###autoload
(defun async-shell-history-rerun-last ()
  "Rerun the most recent `shell-command-history' entry, no prompt.
Runs in the current `default-directory'.  For rerun in a command's
original directory use `recall-rerun' (\\[recall-rerun])."
  (interactive)
  (if-let ((command (car shell-command-history)))
      (progn
        (message "Rerunning: %s" command)
        (async-shell-history--run command
                                  (async-shell-history--buffer-for
                                   command)))
    (user-error "No shell command history yet")))

;;;###autoload
(defun async-shell-history-rerun-buffer (n)
  "Rerun this async-shell buffer's command, like compile's \\`g'.
If a process is still live in the buffer, self-insert instead (N times)
so stdin still works — only rerun once the command has exited.

In an async-shell-command output buffer, `g' reruns that buffer's own
command in place — same buffer, same `default-directory' — like
`g'/`recompile' in a compilation buffer (Emacs already sets a
buffer-local `revert-buffer-function').  But `shell-command-mode'
derives from `comint-mode', so the buffer is interactive: while a
process is live you may be sending it stdin, and `g' must self-insert."
  (interactive "p")
  (if (process-live-p (get-buffer-process (current-buffer)))
      (self-insert-command n)
    (revert-buffer-quick)))

(provide 'async-shell-history)
;;; async-shell-history.el ends here
