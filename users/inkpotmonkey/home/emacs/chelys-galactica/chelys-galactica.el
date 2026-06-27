;;; chelys-galactica.el --- History-aware async-shell-command -*- lexical-binding: t; -*-

;; Author: inkpotmonkey
;; Keywords: convenience, processes
;; Package-Requires: ((emacs "29.1") (marginalia "1.0") (consult "1.0") (recall "0.1"))

;;; Commentary:

;; Front-loads `shell-command-history' (savehist-persisted) as completion
;; candidates so the async-shell-command prompt shows past commands immediately
;; instead of an empty prompt — pick-or-type, always in the current
;; `default-directory'.  `recall' still surveils every launch; its
;; `recall-rerun' remains the rerun-in-original-context tool.  Commands from
;; external shells are merged in too: `chelys-galactica-extra-history-files'
;; (default ~/.bash_history) are read as additional candidates, deduplicated
;; against the Emacs history.
;;
;; Marginalia annotates each candidate with its pinned buffer name (if any),
;; where it last ran, its exit status, and when — read out of `recall-items',
;; since recall already records every async launch.  This needs a completion
;; category on the table (a plain `completing-read' over a list has none, so
;; marginalia has nothing to hang an annotator on), which
;; `chelys-galactica--read-command' supplies.  The recall lookup is soft: with
;; no recall record (or no recall at all) the candidate is simply shown without
;; that part of the annotation.
;;
;; Long commands no longer lose their annotation: candidates wider than the
;; frame are display-truncated (the full command is still matched and run), and
;; annotations are right-aligned for this prompt so they stay on screen.
;;
;; The prompt is a `consult--read', so (taking after atuin's filter modes) the
;; narrowing keys `d'/`p'/`s' restrict candidates to commands `recall' recorded
;; in the current directory, anywhere under the current project/VC root, or
;; whose most recent run succeeded.  Candidates are ordered newest-run-first by
;; default (recency; see `chelys-galactica-sort-by' for frecency/history), and
;; the annotation also shows the most recent run's duration.
;;
;; Duplicate candidates are kept out of the history rather than filtered at the
;; prompt: chosen commands are added through `add-to-history' (the minibuffer's
;; own add is suppressed) and a `:filter-args' advice trims the element first,
;; so with `history-delete-duplicates' non-nil even whitespace-only variants of
;; a command collapse to a single, most-recent entry.
;;
;; Named buffers: `chelys-galactica-run-named' runs a command in a buffer of
;; your choosing and *remembers* the choice — the command→name association is
;; persisted to `chelys-galactica-names-file', so every later
;; `chelys-galactica-run' of that command reopens its named buffer
;; automatically.  A bare name is wrapped in `*' (so `backup' becomes the
;; conventional `*backup*').  `chelys-galactica-forget-name' clears the
;; association.  These, plus `chelys-galactica-edit-command' (edit a command
;; in a scratch buffer before running it) and `chelys-galactica-view-outputs'
;; (browse a command's past runs and their output logs via recall), are also
;; offered as Embark actions on a command candidate (the completion category is
;; `chelys-galactica'); register them when embark loads.
;;
;; You need not decide the name up front: every buffer this package launches is
;; tagged with the command that produced it, and a `rename-buffer' on a tagged
;; buffer pins the command to the new name (via global `:after' advice that is
;; inert on every other buffer).  So renaming `*Async Shell Command*' to
;; `*backup*' after the fact makes future runs reopen `*backup*' too.
;;
;; Commands:
;;   `chelys-galactica-run'          drop-in for `async-shell-command'
;;   `chelys-galactica-run-named'    run in a remembered, named buffer
;;   `chelys-galactica-edit-command' edit a command, then run it
;;   `chelys-galactica-view-outputs'  browse a command's past run logs
;;   `chelys-galactica-forget-name'  drop a command's saved buffer name
;;   `chelys-galactica-rerun-last'   rerun the most recent entry, no prompt
;;   `chelys-galactica-rerun-buffer' rerun an output buffer's own command

;;; Code:

;; marginalia--fields is a macro and marginalia-annotators a defvar, so both
;; must be known at byte-compile time (a plain declare-function would leave the
;; macro unexpanded). marginalia is a hard dependency; recall is soft, so its
;; struct accessors only get declare-function stubs below.
(eval-when-compile
  (require 'marginalia))
;; consult drives the prompt at runtime (narrowing + `consult--read'); it is a
;; hard dependency, so require it rather than soft-guard.
(require 'consult)
;; `marginalia--fields' expands into a `marginalia--truncate' call; it is always
;; loaded when this annotator runs (marginalia is driving the completion), but
;; the compiler can't know that from the eval-when-compile require alone.
(declare-function marginalia--truncate "marginalia")
(declare-function recall--item-command "recall")
(declare-function recall--item-exit-code "recall")
(declare-function recall--item-directory "recall")
(declare-function recall--item-start-time "recall")
(declare-function recall--item-end-time "recall")
(declare-function recall--format-time "recall")
(declare-function recall-list "recall")
(declare-function project-current "project")
(declare-function project-root "project")
(declare-function vc-root-dir "vc-hooks")
(defvar recall-items)
(defvar embark-keymap-alist)
(defvar embark-general-map)

(defgroup chelys-galactica nil
  "History-aware `async-shell-command' with remembered buffer names."
  :group 'processes
  :prefix "chelys-galactica-")

(defcustom chelys-galactica-names-file
  (locate-user-emacs-file "chelys-galactica-names.el")
  "File persisting the command→buffer-name associations.
A plain `read'/`prin1' alist of (COMMAND . BUFFER-NAME) strings."
  :type 'file)

(defcustom chelys-galactica-sort-by 'recency
  "How completion candidates are ordered.
`recency' ranks by each command's most-recent `recall'-recorded run time
\(latest first); `frecency' ranks by `recall'-recorded frequency and recency
\(most-used, recently-used commands first); `history' keeps raw
`shell-command-history' order (most recent first)."
  :type
  '(choice
    (const :tag "Recency (latest run first)" recency)
    (const :tag "Frecency (frequency + recency)" frecency)
    (const :tag "History order" history)))

(defcustom chelys-galactica-command-max-width 72
  "Maximum display width of a command at the prompt, in columns.
Longer commands are display-ellipsized (the full command is still matched
and run).  Caps the command column so a single long command can't push the
right-aligned marginalia annotation across the frame; the effective width
is further limited to leave room for the annotation on narrow frames."
  :type 'natnum)

(defcustom chelys-galactica-extra-history-files '("~/.bash_history")
  "Extra shell history files merged into the completion candidates.
Each is read one command per line; lines beginning with `#' (bash
`HISTTIMEFORMAT' timestamps) and blank lines are skipped.  Commands found
only here carry no `recall' metadata, so they show without annotation and,
under frecency sorting, rank below recall-tracked commands.  Set to nil to
complete from `shell-command-history' alone."
  :type '(repeat file))

(defvar chelys-galactica-names nil
  "Alist mapping command strings to their pinned async-buffer names.")

(defvar chelys-galactica--recall-index nil
  "Hash of normalized-command → list of `recall' items, newest first.
Dynamically bound while reading a command so annotation, ranking and
narrowing share a single pass over `recall-items'.")

(defvar chelys-galactica--names-loaded nil
  "Non-nil once `chelys-galactica-names-file' has been read this session.")

(defvar-local chelys-galactica--command nil
  "The shell command that produced this async-shell output buffer.
Set when the buffer is launched through this package, so renaming the
buffer can pin COMMAND to the new name.")

(defun chelys-galactica--normalize-command (command)
  "Return COMMAND trimmed of surrounding whitespace.
`shell-command-history' entries sometimes carry a trailing space while
`recall' stores the trimmed form; normalizing both sides keeps name
pins and recall annotations matching the same command."
  (and command (string-trim command)))

(defun chelys-galactica--wrap-name (name)
  "Surround NAME with `*' unless it is empty or already wrapped.
So naming a buffer `backup' pins it as the conventional `*backup*'."
  (if (or (null name)
          (string-empty-p name)
          (and (string-prefix-p "*" name) (string-suffix-p "*" name)))
      name
    (concat "*" name "*")))

(defun chelys-galactica--load-names ()
  "Load saved command→buffer-name associations from disk, once.
Keys are normalized on load so older trailing-space entries still match."
  (unless chelys-galactica--names-loaded
    (when (file-readable-p chelys-galactica-names-file)
      (with-temp-buffer
        (insert-file-contents chelys-galactica-names-file)
        (setq chelys-galactica-names
              (mapcar
               (lambda (cell)
                 (cons
                  (chelys-galactica--normalize-command
                   (car cell))
                  (cdr cell)))
               (ignore-errors
                 (read (current-buffer)))))))
    (setq chelys-galactica--names-loaded t)))

(defun chelys-galactica--save-names ()
  "Persist command→buffer-name associations to `chelys-galactica-names-file'."
  (make-directory (file-name-directory chelys-galactica-names-file) t)
  (with-temp-file chelys-galactica-names-file
    (let ((print-length nil)
          (print-level nil))
      (prin1 chelys-galactica-names (current-buffer))
      (insert "\n"))))

(defun chelys-galactica--buffer-for (command)
  "Return the pinned buffer name for COMMAND, or nil."
  (chelys-galactica--load-names)
  (cdr
   (assoc
    (chelys-galactica--normalize-command command)
    chelys-galactica-names)))

(defun chelys-galactica--set-name (command name)
  "Pin COMMAND to buffer NAME and persist it.  An empty NAME clears the pin."
  (chelys-galactica--load-names)
  (let ((command (chelys-galactica--normalize-command command)))
    (if (or (null name) (string-empty-p name))
        (setq chelys-galactica-names
              (assoc-delete-all command chelys-galactica-names))
      (setf (alist-get command chelys-galactica-names nil nil #'equal)
            name)))
  (chelys-galactica--save-names))

(defun chelys-galactica--run
    (command &optional output-buffer error-buffer)
  "Run COMMAND via `async-shell-command', tagging its output buffer.
OUTPUT-BUFFER and ERROR-BUFFER are as in `async-shell-command'.  When the
output goes to a dedicated buffer (OUTPUT-BUFFER nil, a buffer, or a
buffer name) that buffer is tagged with COMMAND via the buffer-local
`chelys-galactica--command', so a later `rename-buffer' can pin the
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
          (setq-local chelys-galactica--command command)))
      result)))

(defun chelys-galactica--remember-on-rename (&rest _)
  "Pin this buffer's command to its new name after `rename-buffer'.
A no-op unless the current buffer is a tagged async-shell output buffer
\(see `chelys-galactica--command'), so it is safe as global advice."
  (when chelys-galactica--command
    (chelys-galactica--set-name
     chelys-galactica--command (buffer-name))))

;; Save-on-rename: renaming a tagged async buffer pins its command to the new
;; name, the same as `chelys-galactica-run-named'.  The advice is global but
;; inert on any buffer this package did not launch.
(advice-add
 'rename-buffer
 :after #'chelys-galactica--remember-on-rename)

(defun chelys-galactica--normalize-history-element (args)
  "Trim a `shell-command-history' element as it enters the history.
`:filter-args' advice for `add-to-history': normalizing on insertion lets
`history-delete-duplicates' collapse whitespace-only variants (e.g. a
trailing space) of the same command into one entry.  ARGS is the full
`add-to-history' argument list; only the element bound for
`shell-command-history' is rewritten."
  (if (eq (car args) 'shell-command-history)
      (cons
       (car args)
       (cons
        (chelys-galactica--normalize-command (cadr args))
        (cddr args)))
    args))

(advice-add
 'add-to-history
 :filter-args #'chelys-galactica--normalize-history-element)

(defun chelys-galactica--build-recall-index ()
  "Index `recall-items' by normalized command, preserving newest-first order."
  (let ((index (make-hash-table :test 'equal)))
    (when (and (fboundp 'recall--item-command) (boundp 'recall-items))
      (dolist (it recall-items)
        (let ((k
               (chelys-galactica--normalize-command
                (recall--item-command it))))
          (puthash k (cons it (gethash k index)) index)))
      ;; recall-items is newest-first and `cons' reverses, so each bucket is
      ;; oldest-first; flip back so callers see the most recent run at the head.
      (maphash (lambda (k v) (puthash k (nreverse v) index)) index))
    index))

(defun chelys-galactica--recall-items-for (command)
  "Return `recall' items for COMMAND, newest first.
Uses `chelys-galactica--recall-index' when bound, else scans directly."
  (let ((key (chelys-galactica--normalize-command command)))
    (if chelys-galactica--recall-index
        (gethash key chelys-galactica--recall-index)
      (and (fboundp 'recall--item-command)
           (boundp 'recall-items)
           (seq-filter
            (lambda (it)
              (equal
               (chelys-galactica--normalize-command
                (recall--item-command it))
               key))
            recall-items)))))

(defun chelys-galactica--frecency (command)
  "Return a frecency score for COMMAND from its `recall' runs.
Each run contributes a recency-weighted point, so a command used often
and recently scores highest.  Zero when `recall' has no record."
  (let ((now (float-time))
        (score 0.0))
    (dolist (it (chelys-galactica--recall-items-for command) score)
      (let ((age
             (- now (time-to-seconds (recall--item-start-time it)))))
        (setq score
              (+ score
                 (cond
                  ((< age 3600)
                   4.0)
                  ((< age 86400)
                   2.0)
                  ((< age 604800)
                   1.0)
                  (t
                   0.5))))))))

(defun chelys-galactica--recency (command)
  "Return the time of COMMAND's most recent `recall' run as a float.
The recall index is newest-first, so the head item is the latest run.
Zero when `recall' has no record, sinking untracked commands below tracked
ones (where they keep their newest-first history order)."
  (let ((it (car (chelys-galactica--recall-items-for command))))
    (if it
        (time-to-seconds (recall--item-start-time it))
      0.0)))

(defun chelys-galactica--sort-by (score-fn commands)
  "Order COMMANDS by SCORE-FN descending.
Ties keep their original (history) order, since Emacs list `sort' is stable."
  (mapcar
   #'cdr
   (sort (mapcar (lambda (c) (cons (funcall score-fn c) c)) commands)
         (lambda (a b) (> (car a) (car b))))))

(defun chelys-galactica--rank (commands)
  "Order COMMANDS per `chelys-galactica-sort-by'.
For `recency', sort by most-recent run time (latest first); for `frecency',
by descending frecency score; `history' keeps `shell-command-history' order.
Ties keep their original (history) order, since Emacs list `sort' is stable."
  (pcase chelys-galactica-sort-by
    ('history commands)
    ('recency
     (chelys-galactica--sort-by #'chelys-galactica--recency commands))
    (_
     (chelys-galactica--sort-by
      #'chelys-galactica--frecency commands))))

(defun chelys-galactica--extra-history-commands ()
  "Commands read from `chelys-galactica-extra-history-files', newest first.
Skips blank lines and `#'-prefixed lines (bash `HISTTIMEFORMAT' stamps).
Missing/unreadable files are silently ignored."
  (let (commands)
    (dolist (file chelys-galactica-extra-history-files)
      (let ((path (expand-file-name file)))
        (when (file-readable-p path)
          (with-temp-buffer
            (insert-file-contents path)
            (goto-char (point-min))
            (while (not (eobp))
              (let ((line
                     (buffer-substring-no-properties
                      (line-beginning-position) (line-end-position))))
                ;; File is oldest-first; pushing yields newest-first.
                (unless (or (string-empty-p line)
                            (eq (aref line 0) ?#))
                  (push (string-trim line) commands)))
              (forward-line 1))))))
    commands))

(defun chelys-galactica--candidate-commands ()
  "Return the completion command list, deduplicated (normalized, first wins).
`shell-command-history' (recall-tracked, listed first so it wins ties) plus
the commands from `chelys-galactica-extra-history-files'."
  (let ((seen (make-hash-table :test 'equal))
        (result nil))
    (dolist (command
             (append
              shell-command-history
              (chelys-galactica--extra-history-commands)))
      (let ((key (chelys-galactica--normalize-command command)))
        (unless (or (string-empty-p key) (gethash key seen))
          (puthash key t seen)
          (push command result))))
    (nreverse result)))

(defun chelys-galactica--format-duration (item)
  "Return ITEM's run duration as a short human string, or nil if unfinished."
  (when-let* ((start (recall--item-start-time item))
              (end (recall--item-end-time item)))
    (let ((secs (- (time-to-seconds end) (time-to-seconds start))))
      (cond
       ((< secs 1)
        (format "%dms" (round (* secs 1000))))
       ((< secs 60)
        (format "%.1fs" secs))
       ((< secs 3600)
        (format "%dm%ds" (floor secs 60) (mod (round secs) 60)))
       (t
        (format "%dh%dm"
                (floor secs 3600)
                (mod (floor (/ secs 60)) 60)))))))

(defun chelys-galactica--truncate-candidate (command width)
  "Return COMMAND, display-ellipsized when wider than WIDTH columns.
Only the on-screen DISPLAY is shortened — the string's text is unchanged,
so it still matches `shell-command-history' and is run verbatim."
  (if (<= (string-width command) width)
      command
    (let ((copy (copy-sequence command))
          (cut
           (length
            (truncate-string-to-width command (max 1 (1- width))))))
      (put-text-property cut (length copy) 'display "…" copy)
      copy)))

(defvar chelys-galactica--read-directory nil
  "`default-directory' captured at the start of a read, for `d' narrowing.")

(defvar chelys-galactica--read-project-root nil
  "Project/VC root captured at the start of a read, for `p' narrowing.")

(defvar chelys-galactica--narrow-keys
  '((?d . "directory") (?p . "project") (?s . "succeeded"))
  "Narrowing keys offered at the chelys-galactica prompt.
`d' keeps commands run in the current directory, `p' those run anywhere
under the current project/VC root, `s' those whose most recent run
succeeded.  Atuin's filter modes, as consult narrowing.")

(defun chelys-galactica--project-root ()
  "Return the current project or VC root directory, expanded, or nil."
  (or (and (fboundp 'project-current)
           (when-let* ((proj (project-current nil)))
             (expand-file-name (project-root proj))))
      (and (fboundp 'vc-root-dir)
           (when-let* ((root (vc-root-dir)))
             (expand-file-name root)))))

(defun chelys-galactica--narrow-predicate (command)
  "Keep COMMAND under the active `consult--narrow' filter.
`?d' keeps commands `recall' recorded in the read's directory, `?p' those
anywhere under its project/VC root, `?s' those whose most recent run
exited successfully.  Any other (or no) narrow key keeps everything."
  (let ((items (chelys-galactica--recall-items-for command)))
    (pcase consult--narrow
      (?d
       (seq-some
        (lambda (it)
          (when-let* ((d (recall--item-directory it)))
            (string-equal
             (directory-file-name (expand-file-name d))
             (directory-file-name chelys-galactica--read-directory))))
        items))
      (?p
       (when-let* ((root chelys-galactica--read-project-root))
         (seq-some
          (lambda (it)
            (when-let* ((d (recall--item-directory it)))
              (string-prefix-p
               root (file-name-as-directory (expand-file-name d)))))
          items)))
      (?s
       (when-let* ((it (car items)))
         (eql (recall--item-exit-code it) 0)))
      (_ t))))

(defun chelys-galactica--read-command ()
  "Read a shell command, completing from `shell-command-history'.
Candidates are frecency-ranked, display-truncated when wider than the
frame, and annotated by marginalia (right-aligned for this prompt).  Built
on `consult--read', so the `d'/`p'/`s' narrowing keys filter to the current
directory, project, or successful commands — atuin's filter modes.  History
insertion is routed through `add-to-history' (the minibuffer's own add
suppressed) so the normalizing advice and `history-delete-duplicates' apply
to the choice."
  (let* ((width
          (max 20
               (min chelys-galactica-command-max-width
                    (- (frame-width) 50))))
         (chelys-galactica--recall-index
          (chelys-galactica--build-recall-index))
         (chelys-galactica--read-directory
          (expand-file-name default-directory))
         (chelys-galactica--read-project-root
          (chelys-galactica--project-root))
         (cands
          (mapcar
           (lambda (c) (chelys-galactica--truncate-candidate c width))
           (chelys-galactica--rank
            (chelys-galactica--candidate-commands))))
         (marginalia-align 'right)
         (history-add-new-input nil)
         (command
          (substring-no-properties
           (consult--read
            cands
            :prompt "Async shell command: "
            :category 'chelys-galactica
            :sort nil
            :require-match nil
            :history 'shell-command-history
            :narrow
            (list
             :predicate #'chelys-galactica--narrow-predicate
             :keys chelys-galactica--narrow-keys)))))
    (add-to-history 'shell-command-history command)
    command))

(defun chelys-galactica--annotate (command)
  "Marginalia annotation for COMMAND.
Shows its pinned buffer name (if any) plus, when `recall' has a record,
the exit status, how long the most recent run took, the directory it ran
in, and how long ago.  Returns nil when there is nothing to show (a
brand-new, unpinned command)."
  (let* ((name (chelys-galactica--buffer-for command))
         (item (car (chelys-galactica--recall-items-for command)))
         (code (and item (recall--item-exit-code item)))
         (duration
          (and item (chelys-galactica--format-duration item)))
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
       ((or duration "") :width 7 :face 'marginalia-number)
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
   '(chelys-galactica chelys-galactica--annotate builtin none)))

;; Embark actions on a command candidate.  Kept here (not in init.el) because
;; the only way to reach an `chelys-galactica'-category prompt is to invoke
;; one of our commands, which loads this file — running this registration —
;; before `embark-act' can be pressed.
(with-eval-after-load 'embark
  (defvar-keymap chelys-galactica-embark-map
    :doc "Embark actions for `chelys-galactica' command candidates."
    :parent
    embark-general-map
    "r"
    #'chelys-galactica-run
    "n"
    #'chelys-galactica-run-named
    "e"
    #'chelys-galactica-edit-command
    "o"
    #'chelys-galactica-view-outputs
    "k"
    #'chelys-galactica-forget-name)
  (add-to-list
   'embark-keymap-alist
   '(chelys-galactica . chelys-galactica-embark-map)))

;;;###autoload
(defun chelys-galactica-run
    (command &optional output-buffer error-buffer)
  "Like `async-shell-command' but completes from `shell-command-history'.
COMMAND is read with `shell-command-history' as candidates (pick an old
command or type a new one).  If COMMAND has a pinned buffer name (see
`chelys-galactica-run-named') its output goes there.  OUTPUT-BUFFER and
ERROR-BUFFER are passed through unchanged, mirroring `async-shell-command'
\(prefix arg inserts output at point)."
  (interactive (list
                (chelys-galactica--read-command)
                current-prefix-arg
                shell-command-default-error-buffer))
  (chelys-galactica--run command
                         (or output-buffer
                             (chelys-galactica--buffer-for command))
                         error-buffer))

;;;###autoload
(defun chelys-galactica-run-named (command &optional name)
  "Run COMMAND asynchronously in a buffer named NAME and remember NAME.
Interactively, read COMMAND (from history), then prompt for NAME,
defaulting to any name already pinned to COMMAND.  The COMMAND→NAME
association is persisted to `chelys-galactica-names-file', so later
`chelys-galactica-run' calls reopen the named buffer automatically.
An empty NAME clears any pinned association and runs in the default
buffer.  Also available as the `n' Embark action on a candidate."
  (interactive (let* ((command (chelys-galactica--read-command))
                      (saved (chelys-galactica--buffer-for command))
                      (name
                       (read-string
                        (if saved
                            (format
                             "Buffer name for `%s' (default %s): "
                             command saved)
                          (format "Buffer name for `%s': " command))
                        nil nil saved)))
                 (list command name)))
  (let ((name (chelys-galactica--wrap-name name)))
    (chelys-galactica--set-name command name)
    (chelys-galactica--run command
                           (and (not (string-empty-p name)) name))))

;;;###autoload
(defun chelys-galactica-forget-name (command)
  "Drop the pinned buffer name for COMMAND, if any.
Interactively, read COMMAND from history.  Also available as the `k'
Embark action on a candidate."
  (interactive (list (chelys-galactica--read-command)))
  (chelys-galactica--set-name command nil)
  (message "Forgot saved buffer name for: %s" command))

;;;###autoload
(defun chelys-galactica-view-outputs (command)
  "Browse every recorded run of COMMAND and its output, via `recall'.
Pops a `recall-list' buffer scoped to the `recall' items for COMMAND — one
row per past run, with its directory, exit code, duration and time — where
RET (`recall-do-find-log') opens that run's saved output log, and recall's
other bindings rerun or delete it.

Interactively reads COMMAND from history; also bound to `o' in the
chelys-galactica Embark map.  Runs whose `.log' was pruned (see
`recall-prune-after') are still listed; opening one just shows an empty log.

Note: `recall-list' scopes to the items it is passed — its own docstring
says it \"display[s] all processes\", but `recall--list-refresh' rebuilds
the table from `recall-list-items', which `recall-list' sets to ITEMS."
  (interactive (list (chelys-galactica--read-command)))
  (unless (require 'recall nil t)
    (user-error "recall is not available"))
  (let ((items (chelys-galactica--recall-items-for command)))
    (unless items
      (user-error "No recorded runs for: %s" command))
    (recall-list items)))

;;;###autoload
(defun chelys-galactica-rerun-last ()
  "Rerun the most recent `shell-command-history' entry, no prompt.
Runs in the current `default-directory'.  For rerun in a command's
original directory use `recall-rerun' (\\[recall-rerun])."
  (interactive)
  (if-let ((command (car shell-command-history)))
      (progn
        (message "Rerunning: %s" command)
        (chelys-galactica--run command
                               (chelys-galactica--buffer-for
                                command)))
    (user-error "No shell command history yet")))

;;;###autoload
(defun chelys-galactica-rerun-buffer (n)
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

;;; Edit-then-run

(defvar chelys-galactica--edit-buffer-name
  "*Async Shell Command Edit*"
  "Name of the scratch buffer used to edit a command before running it.")

(defvar-keymap chelys-galactica-edit-mode-map
  :doc
  "Keymap while editing an async shell command before running it."
  "C-c C-c"
  #'chelys-galactica-edit-finish
  "C-c C-k"
  #'chelys-galactica-edit-abort)

(define-minor-mode chelys-galactica-edit-mode
  "Minor mode for editing an async shell command before running it.
\\<chelys-galactica-edit-mode-map>\\[chelys-galactica-edit-finish] \
runs the edited command; \\[chelys-galactica-edit-abort] cancels."
  :lighter " ShEdit")

(defun chelys-galactica-edit-finish ()
  "Run the command being edited in this buffer, then bury the buffer."
  (interactive)
  (let ((command (string-trim (buffer-string))))
    (when (string-empty-p command)
      (user-error "Empty command"))
    (quit-window t (selected-window))
    (add-to-history 'shell-command-history command)
    (chelys-galactica-run command)))

(defun chelys-galactica-edit-abort ()
  "Abandon the command being edited and bury the buffer."
  (interactive)
  (quit-window t (selected-window)))

;;;###autoload
(defun chelys-galactica-edit-command (command)
  "Edit COMMAND in a dedicated buffer, then run it on \\`C-c C-c'.
Pops a `sh-mode' scratch buffer pre-filled with COMMAND (read from
`shell-command-history' interactively) so it can be tweaked — multi-line
and with shell highlighting — before launching.  \\`C-c C-c' runs the
edited command through `chelys-galactica-run' (so a pinned buffer name
still applies) and records it in history; \\`C-c C-k' cancels.  Also
available as the `e' Embark action on a candidate."
  (interactive (list (chelys-galactica--read-command)))
  (let ((buffer
         (get-buffer-create chelys-galactica--edit-buffer-name)))
    (with-current-buffer buffer
      (erase-buffer)
      (insert command)
      (when (fboundp 'sh-mode)
        (sh-mode))
      (chelys-galactica-edit-mode)
      (setq-local
       header-line-format
       (substitute-command-keys
        "Edit, then \\<chelys-galactica-edit-mode-map>\\[chelys-galactica-edit-finish] to run, \\[chelys-galactica-edit-abort] to cancel")))
    (pop-to-buffer buffer)))

(provide 'chelys-galactica)
;;; chelys-galactica.el ends here
