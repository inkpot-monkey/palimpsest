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
;; Marginalia annotates each candidate with where it last ran, its exit status,
;; and when — read out of `recall-items', since recall already records every
;; async launch.  This needs a completion category on the table (a plain
;; `completing-read' over a list has none, so marginalia has nothing to hang an
;; annotator on), which `async-shell-history--collection' supplies.  The recall
;; lookup is soft: with no recall record (or no recall at all) the candidate is
;; simply shown without an annotation.
;;
;; Commands:
;;   `async-shell-history-run'          drop-in for `async-shell-command'
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

(defun async-shell-history--annotate (command)
  "Marginalia annotation for COMMAND, sourced from `recall-items'.
Shows the directory it last ran in, its exit status, and how long ago.
Returns nil when recall has no record of COMMAND (e.g. a brand-new
command, or one only ever run as a synchronous `shell-command')."
  (when (and (fboundp 'recall--item-command) (boundp 'recall-items))
    (when-let ((item
                (seq-find
                 (lambda (it)
                   (string-equal (recall--item-command it) command))
                 recall-items)))
      (let ((code (recall--item-exit-code item))
            (dir (recall--item-directory item))
            (start (recall--item-start-time item)))
        (marginalia--fields
         ((cond
           ((null code)
            "")
           ((eql code 0)
            (propertize "ok" 'face 'marginalia-on))
           (t
            (propertize (format "exit %s" code)
                        'face
                        'marginalia-off)))
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
          :face 'marginalia-date))))))

(with-eval-after-load 'marginalia
  (add-to-list
   'marginalia-annotators
   '(async-shell-history async-shell-history--annotate builtin none)))

;;;###autoload
(defun async-shell-history-run
    (command &optional output-buffer error-buffer)
  "Like `async-shell-command' but completes from `shell-command-history'.
COMMAND is read with `shell-command-history' as candidates (pick an old
command or type a new one).  OUTPUT-BUFFER and ERROR-BUFFER are passed
through unchanged, mirroring `async-shell-command' (prefix arg inserts
output at point)."
  (interactive (list
                (completing-read "Async shell command: "
                                 #'async-shell-history--collection
                                 nil
                                 nil
                                 nil
                                 'shell-command-history)
                current-prefix-arg
                shell-command-default-error-buffer))
  (async-shell-command command output-buffer error-buffer))

;;;###autoload
(defun async-shell-history-rerun-last ()
  "Rerun the most recent `shell-command-history' entry, no prompt.
Runs in the current `default-directory'.  For rerun in a command's
original directory use `recall-rerun' (\\[recall-rerun])."
  (interactive)
  (if-let ((command (car shell-command-history)))
      (progn
        (message "Rerunning: %s" command)
        (async-shell-command command))
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
