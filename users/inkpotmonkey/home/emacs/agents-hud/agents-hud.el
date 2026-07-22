;;; agents-hud.el --- Live status view + switcher for Claude/ghostel buffers -*- lexical-binding: t; -*-

;; Author: inkpotmonkey
;; Keywords: processes, terminals, ai, convenience
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; A single status backend feeding two front-ends for the terminal/agent
;; buffers you run: every live claude-code session (`*claude:…*') and every
;; plain ghostel terminal (`*ghostel:…*').  Both are `ghostel-mode' buffers
;; (claude-code drives the ghostel backend), so one collector covers them.
;;
;;   * `agents-hud-toggle-sidebar' (C-x C-a) — a persistent right-side panel,
;;     grouped by project, that live-updates on a timer.  Rows carry a status
;;     icon, the project + working directory, the instance name, and how long
;;     the current state has held.  WAITING rows float to the top of their
;;     group and groups with a waiting/working session sort first, so what
;;     needs you is always near the top.
;;
;;   * `agents-hud-consult-source' / `agents-hud-picker' (C-c c b) — the same
;;     buffers as a narrowable consult group (folded into `consult-buffer', or
;;     opened directly), attention-sorted, with `SPC' preview.
;;
;; STATUS MODEL (per buffer), four states:
;;
;;   ⧗ working — the terminal is churning: either ghostel's own OSC-133
;;               `ghostel--command-running' flag is set (a shell command is
;;               running) or a redraw fired within `agents-hud-idle-seconds'.
;;   ! waiting — Claude finished its turn and wants you.  Claude's only clean
;;               "done" event is the terminal BELL; we read it two ways (either
;;               suffices): membership in `proc-notify--pending' (proc-notify
;;               already captures the bell) and a best-effort `:after' advice on
;;               `claude-code--notify' that stamps a bell time on the buffer.
;;   ○ idle    — a live process, quiet past the cutoff, not waiting.
;;   ✕ dead    — no live process (only visible if the buffer lingers;
;;               `ghostel-kill-buffer-on-exit' defaults to t, so exited
;;               terminals usually vanish rather than show here).
;;
;; The state-tracking side effects (activity stamp, bell stamp, exit code) are
;; installed by `agents-hud-setup', which is idempotent and degrades quietly
;; when claude-code / ghostel / proc-notify are absent.  Everything the two
;; front-ends render is derived from those buffer-local stamps by pure
;; functions (`agents-hud--compute-state', `--sort-entries',
;; `--group-by-project', `--format-…'), which is what the ERT suite exercises.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'project)

;; Soft dependencies — never `require'd, so the package (and its ERT suite)
;; loads with only built-ins present.  Guarded at every call site with
;; `fboundp' / `bound-and-true-p'.
(defvar proc-notify--pending)
(defvar consult-buffer-sources)
(declare-function claude-code "claude-code" (&optional arg))
(declare-function claude-code--notify "claude-code" (terminal))
(declare-function ghostel "ghostel" (&optional arg))
(declare-function ghostel-project "ghostel" (&optional arg))
(declare-function consult--buffer-state "consult" ())
(declare-function consult--multi "consult" (sources &rest options))
(declare-function nerd-icons-mdicon "nerd-icons" (name &rest args))
(declare-function nerd-icons-faicon "nerd-icons" (name &rest args))
(declare-function nerd-icons-icon-for-buffer "nerd-icons"
                  (&rest args))
(declare-function avy-process "avy"
                  (candidates &optional overlay-fn cleanup-fn))
(defvar avy-action)

;;; ── Customization ────────────────────────────────────────────────────────────

(defgroup agents-hud nil
  "Live status view and switcher for Claude/ghostel buffers."
  :group 'convenience
  :prefix "agents-hud-")

(defcustom agents-hud-idle-seconds 3.0
  "Seconds of terminal quiet after which a working buffer is called idle.
A redraw within this window counts the buffer as ⧗ working; once redraws stop
for this long (and no shell command is running) it drops to ○ idle."
  :type 'number)

(defcustom agents-hud-refresh-interval 1.0
  "Seconds between automatic sidebar re-renders while the panel is visible.
The tick also advances the displayed durations and flips working→idle."
  :type 'number)

(defcustom agents-hud-side 'right
  "Side of the frame the sidebar window opens on."
  :type '(choice (const left) (const right)))

(defcustom agents-hud-width 36
  "Width in columns of the sidebar window."
  :type 'integer)

(defcustom agents-hud-working-icon "⧗"
  "Icon for the ⧗ working state."
  :type 'string)

(defcustom agents-hud-waiting-icon "!"
  "Icon for the ! waiting-on-you state."
  :type 'string)

(defcustom agents-hud-idle-icon "○"
  "Icon for the ○ idle state."
  :type 'string)

(defcustom agents-hud-dead-icon "✕"
  "Icon for the ✕ dead state."
  :type 'string)

(defcustom agents-hud-claude-glyph "◆"
  "Subtle leading glyph marking a Claude agent buffer."
  :type 'string)

(defcustom agents-hud-shell-glyph "$"
  "Subtle leading glyph marking a plain ghostel shell buffer."
  :type 'string)

(defcustom agents-hud-claude-icon "nf-md-creation"
  "nerd-icons Material-Design glyph name for a Claude session.
There is no Claude/Anthropic brand glyph in nerd fonts; the default is the
sparkle (closest to Claude's logo).  Other options: \"nf-md-robot\",
\"nf-md-brain\", \"nf-md-star_four_points\".  Rendered with `nerd-icons-mdicon'."
  :type 'string)

(defcustom agents-hud-shell-icon "nf-fa-terminal"
  "nerd-icons Font-Awesome glyph name for a plain ghostel shell.
Rendered with `nerd-icons-faicon'."
  :type 'string)

(defcustom agents-hud-show-state-label nil
  "When non-nil, spell out the state word (working/idle/…) in the sidebar.
Off by default: the leading state icon (⧗ ! ○ ✕) carries the status and the
row stays compact.  A dead buffer's exit code is shown either way."
  :type 'boolean)

(defface agents-hud-working-face '((t :inherit warning))
  "Face for the working state icon and status text.")

(defface agents-hud-waiting-face '((t :inherit error :weight bold))
  "Face for the waiting-on-you state icon and status text.")

(defface agents-hud-idle-face '((t :inherit shadow))
  "Face for the idle state icon and status text.")

(defface agents-hud-dead-face '((t :inherit font-lock-comment-face))
  "Face for the dead state icon and status text.")

(defface agents-hud-heading-face '((t :inherit bold))
  "Face for project group headings in the sidebar.")

(defface agents-hud-path-face '((t :inherit font-lock-comment-face))
  "Face for the working-directory path in a row.")

;;; ── State tracking (buffer-local stamps) ─────────────────────────────────────

(defvar-local agents-hud--activity nil
  "`float-time' of this buffer's last terminal redraw, or nil.")

(defvar-local agents-hud--working-since nil
  "`float-time' the current active burst began, for the working duration.")

(defvar-local agents-hud--bell nil
  "`float-time' of the last claude-code finished-turn bell in this buffer.")

(defvar-local agents-hud--exit nil
  "Exit code recorded when this buffer's terminal process exited, or nil.")

(defun agents-hud--note-activity (buffer)
  "Stamp BUFFER's last-activity time on a redraw; never inhibit the redraw.
For `ghostel-inhibit-redraw-functions' (called with BUFFER current before each
redraw): returns nil so the redraw always proceeds.  When activity resumes
after a quiet spell it also restarts `agents-hud--working-since' so the working
duration measures the current burst, not the whole session."
  (with-demoted-errors "agents-hud activity: %S"
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((now (float-time)))
          (when (or (null agents-hud--activity)
                    (>= (- now agents-hud--activity)
                        agents-hud-idle-seconds))
            (setq agents-hud--working-since now))
          (setq agents-hud--activity now)))))
  nil)

(defun agents-hud--note-bell (&rest _)
  "Stamp a finished-turn bell time on the current (Claude) buffer.
For `:after' advice on `claude-code--notify', which runs in the Claude terminal
buffer.  Best-effort: `proc-notify--pending' is the primary waiting signal, so
this only has to work when proc-notify is absent or the buffer is being
watched (which proc-notify suppresses)."
  (with-demoted-errors "agents-hud bell: %S"
    (setq agents-hud--bell (float-time))))

(defun agents-hud--note-exit (buffer event)
  "Record BUFFER's process exit code parsed from EVENT.
For `ghostel-exit-functions', which fires before the buffer may be killed."
  (with-demoted-errors "agents-hud exit: %S"
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq agents-hud--exit
              (cond
               ((string-match "code \\([0-9]+\\)" event)
                (string-to-number (match-string 1 event)))
               ((string-match-p "finished" event)
                0)
               (t
                nil)))))))

(defvar agents-hud--setup-done nil
  "Non-nil once `agents-hud-setup' has installed its hooks/advice.")

;;;###autoload
(defun agents-hud-setup ()
  "Install the state-tracking hooks and advice (idempotent).
Wires redraw-activity stamping and exit recording on ghostel, a best-effort bell
stamp on claude-code, and per-type completion icons on nerd-icons.  Safe to call
when those packages are not yet loaded; the pieces attach as they become
available."
  (interactive)
  (unless agents-hud--setup-done
    (with-eval-after-load 'ghostel
      (add-hook
       'ghostel-inhibit-redraw-functions #'agents-hud--note-activity)
      (add-hook 'ghostel-exit-functions #'agents-hud--note-exit))
    (with-eval-after-load 'claude-code
      (advice-add
       'claude-code--notify
       :after #'agents-hud--note-bell))
    (with-eval-after-load 'nerd-icons
      (advice-add
       'nerd-icons-icon-for-buffer
       :around #'agents-hud--nerd-icon-for-buffer))
    (setq agents-hud--setup-done t)))

;;; ── Discovery ────────────────────────────────────────────────────────────────

(defun agents-hud--claude-buffer-p (buffer)
  "Non-nil when BUFFER is a claude-code session buffer."
  (string-prefix-p "*claude:" (buffer-name buffer)))

(defun agents-hud--ghostel-mode-p (buffer)
  "Non-nil when BUFFER is a ghostel-mode buffer (claude or plain shell)."
  (provided-mode-derived-p (buffer-local-value 'major-mode buffer)
                           'ghostel-mode))

(defun agents-hud--buffers ()
  "Return live Claude/ghostel buffers to display."
  (seq-filter
   (lambda (b)
     (and (buffer-live-p b)
          (or (agents-hud--ghostel-mode-p b)
              (agents-hud--claude-buffer-p b))))
   (buffer-list)))

(defun agents-hud--buffer-type (buffer)
  "Return \\='claude or \\='shell for BUFFER."
  (if (agents-hud--claude-buffer-p buffer)
      'claude
    'shell))

(defun agents-hud--git (dir &rest args)
  "Run git with ARGS in DIR; return trimmed stdout, or nil on failure."
  (when (and dir (file-directory-p dir) (executable-find "git"))
    (let ((default-directory (file-name-as-directory dir)))
      (with-temp-buffer
        (when (eq
               0
               (ignore-errors
                 (apply #'process-file "git" nil t nil args)))
          (let ((s (string-trim (buffer-string))))
            (unless (string-empty-p s)
              s)))))))

(defun agents-hud--buffer-dir (buffer)
  "Return BUFFER's live working directory (OSC-7 cwd if tracked)."
  (with-current-buffer buffer
    (or (and (boundp 'ghostel--last-directory)
             ghostel--last-directory)
        default-directory)))

(defun agents-hud--buffer-path (buffer)
  "Return BUFFER's live working directory, abbreviated for display."
  (abbreviate-file-name
   (directory-file-name (or (agents-hud--buffer-dir buffer) "~"))))

(defvar agents-hud--repo-root-cache (make-hash-table :test 'equal)
  "Memoises `agents-hud--repo-root' per directory.
A value of \\='none means \"checked, not a repo\".  Cleared on
`agents-hud-refresh' so an explicit `g' re-resolves worktree topology.")

(defun agents-hud--repo-root (dir)
  "Return the MAIN worktree root for DIR, or nil when DIR is not in a git repo.
Linked worktrees collapse onto their parent repository: git reports the same
`--git-common-dir' (…/.git) for every worktree of a repo, so its parent
directory is the shared root.  This keeps sibling worktrees (e.g. a project's
`.claude/worktrees/*') grouped under the one project instead of splitting out."
  (when (and dir (file-directory-p dir))
    (let* ((key (directory-file-name (expand-file-name dir)))
           (cached (gethash key agents-hud--repo-root-cache)))
      (cond
       ((eq cached 'none)
        nil)
       (cached
        cached)
       (t
        (let* ((common
                (agents-hud--git key
                                 "rev-parse"
                                 "--path-format=absolute"
                                 "--git-common-dir"))
               (root
                (and common
                     (string-suffix-p ".git" common)
                     (directory-file-name
                      (file-name-directory
                       (directory-file-name common))))))
          (puthash key (or root 'none) agents-hud--repo-root-cache)
          root))))))

(defvar agents-hud--worktree-cache (make-hash-table :test 'equal)
  "Memoises `agents-hud--worktree-tag' per directory (\\='none = no tag).
Cleared with the repo-root cache on `agents-hud-refresh'.")

(defun agents-hud--worktree-tag (dir repo-root)
  "Return a short id for DIR's git worktree within REPO-ROOT, or nil.
A linked worktree is named by its own directory basename; the main worktree is
named by its current branch.  Because sibling worktrees group under one repo,
this is what keeps their rows tellable apart."
  (when (and dir repo-root)
    (let* ((key (directory-file-name (expand-file-name dir)))
           (cached (gethash key agents-hud--worktree-cache 'miss)))
      (if (not (eq cached 'miss))
          (unless (eq cached 'none)
            cached)
        (let* ((top
                (agents-hud--git key "rev-parse" "--show-toplevel"))
               (tag
                (cond
                 ((null top)
                  nil)
                 ((equal
                   (directory-file-name top)
                   (directory-file-name repo-root))
                  (agents-hud--git key
                                   "rev-parse"
                                   "--abbrev-ref"
                                   "HEAD"))
                 (t
                  (file-name-nondirectory
                   (directory-file-name top))))))
          (puthash key (or tag 'none) agents-hud--worktree-cache)
          tag)))))

(defun agents-hud--buffer-project (buffer)
  "Return BUFFER's project root, collapsing git worktrees onto their repo.
Falls back to `project-current' when the buffer is in a non-git project, and
nil when it is in no project at all."
  (let ((dir (agents-hud--buffer-dir buffer)))
    (or (agents-hud--repo-root dir)
        (with-current-buffer buffer
          (when-let ((proj
                      (ignore-errors
                        (project-current nil))))
            (directory-file-name (project-root proj)))))))

(defun agents-hud--buffer-instance (buffer type)
  "Return the instance/session name for BUFFER of TYPE, or nil.
For claude buffers this is the `:name' suffix (`*claude:DIR:name*'); for plain
ghostel buffers it is the title portion of `*ghostel: TITLE*'."
  (let ((name (buffer-name buffer)))
    (pcase type
      ('claude
       (when (string-match
              "\\`\\*claude:[^:]+:\\([^*]+\\)\\*\\'" name)
         (match-string 1 name)))
      (_
       (when (string-match "\\`\\*ghostel:? *\\(.+?\\) *\\*\\'" name)
         (match-string 1 name))))))

;;; ── State computation (pure) ─────────────────────────────────────────────────

(cl-defstruct
 (agents-hud-entry (:constructor agents-hud-entry--create))
 buffer
 type
 project
 worktree
 path
 instance
 state
 since
 exit)

(defun agents-hud--waiting-p (pending bell activity)
  "Non-nil when a buffer counts as waiting-on-you.
PENDING is whether it is in proc-notify's pending set; BELL/ACTIVITY are its
last bell and last redraw times.  A bell with no output since it means Claude
finished and is parked; PENDING covers the same via proc-notify."
  (or (and pending t)
      (and bell (or (null activity) (<= activity bell)))))

(cl-defun
 agents-hud--compute-state
 (&key
  live
  cmd-running
  waiting
  activity
  (now (float-time))
  (cutoff agents-hud-idle-seconds))
 "Resolve a buffer's status symbol from its signals.
LIVE — has a live process.  CMD-RUNNING — ghostel's OSC-133 flag.  WAITING —
already-resolved waiting-on-you flag.  ACTIVITY — last redraw `float-time'.
Priority: dead → waiting → working → idle."
 (cond
  ((not live)
   'dead)
  (waiting
   'waiting)
  (cmd-running
   'working)
  ((and activity (< (- now activity) cutoff))
   'working)
  (t
   'idle)))

(defun agents-hud--buffer-pending-p (buffer)
  "Non-nil when BUFFER is in proc-notify's pending set (if proc-notify loaded)."
  (and (bound-and-true-p proc-notify--pending)
       (memq buffer proc-notify--pending)
       t))

(defun agents-hud--entry (buffer &optional now)
  "Build a `agents-hud-entry' snapshot for BUFFER at time NOW."
  (let* ((now (or now (float-time)))
         (type (agents-hud--buffer-type buffer))
         (proc (get-buffer-process buffer))
         (live (and proc (process-live-p proc)))
         (activity (buffer-local-value 'agents-hud--activity buffer))
         (working-since
          (buffer-local-value 'agents-hud--working-since buffer))
         (bell (buffer-local-value 'agents-hud--bell buffer))
         (cmd-running
          (and (boundp 'ghostel--command-running)
               (buffer-local-value 'ghostel--command-running buffer)))
         (waiting
          (agents-hud--waiting-p
           (agents-hud--buffer-pending-p buffer) bell activity))
         (state
          (agents-hud--compute-state
           :live live
           :cmd-running cmd-running
           :waiting waiting
           :activity activity
           :now now))
         (since
          (pcase state
            ('waiting (or bell now))
            ('working (or working-since activity now))
            ('idle (or activity now))
            (_ nil)))
         (project (agents-hud--buffer-project buffer)))
    (agents-hud-entry--create
     :buffer buffer
     :type type
     :project project
     :worktree
     (agents-hud--worktree-tag
      (agents-hud--buffer-dir buffer) project)
     :path (agents-hud--buffer-path buffer)
     :instance (agents-hud--buffer-instance buffer type)
     :state state
     :since since
     :exit (buffer-local-value 'agents-hud--exit buffer))))

(defun agents-hud--entries (&optional now)
  "Return `agents-hud-entry' snapshots for all live Claude/ghostel buffers."
  (let ((now (or now (float-time))))
    (mapcar
     (lambda (b) (agents-hud--entry b now)) (agents-hud--buffers))))

;;; ── Sorting & grouping (pure) ────────────────────────────────────────────────

(defconst agents-hud--state-priority
  '((waiting . 0) (working . 1) (idle . 2) (dead . 3))
  "Sort rank per state — lower floats to the top (attention first).")

(defun agents-hud--entry-priority (entry)
  "Return the sort rank of ENTRY's state."
  (or (alist-get
       (agents-hud-entry-state entry) agents-hud--state-priority)
      9))

(defun agents-hud--entry-label (entry &optional relative)
  "Return the display/sort label for ENTRY.
The worktree/branch tag distinguishes sibling worktrees, which group under one
repo.  With RELATIVE (sidebar rows, already under the repo heading) the label
leads with that tag and omits the repo; otherwise it is repo-qualified
\(\"repo/worktree\") so it stands alone in the flat consult list."
  (let* ((proj (agents-hud-entry-project entry))
         (repo (and proj (file-name-nondirectory proj)))
         (wt (agents-hud-entry-worktree entry))
         (fallback
          (when-let ((p (agents-hud-entry-path entry)))
            (file-name-nondirectory p)))
         (base
          (if relative
              (or wt repo fallback)
            (let ((r (or repo fallback)))
              (if (and wt (not (string= wt r)))
                  (format "%s/%s" r wt)
                r))))
         (inst (agents-hud-entry-instance entry)))
    (if (and inst (not (string= inst base)))
        (format "%s:%s" base inst)
      base)))

(defun agents-hud--sort-entries (entries)
  "Return ENTRIES sorted attention-first, then by label (stable)."
  (sort (copy-sequence entries)
        (lambda (a b)
          (let ((pa (agents-hud--entry-priority a))
                (pb (agents-hud--entry-priority b)))
            (if (/= pa pb)
                (< pa pb)
              (string<
               (agents-hud--entry-label a)
               (agents-hud--entry-label b)))))))

(defun agents-hud--group-key (entry)
  "Return the grouping key (project root, else path) for ENTRY."
  (or (agents-hud-entry-project entry) (agents-hud-entry-path entry)))

(defun agents-hud--group-by-project (entries)
  "Group ENTRIES by project into (GROUP-KEY . SORTED-ENTRIES) pairs.
Rows within a group are attention-sorted; groups with an attention-needing
session sort ahead of quiet ones, then alphabetically by key."
  (let ((groups '()))
    (dolist (e entries)
      (let* ((key (agents-hud--group-key e))
             (cell (assoc key groups)))
        (if cell
            (setcdr cell (cons e (cdr cell)))
          (push (cons key (list e)) groups))))
    (setq groups
          (mapcar
           (lambda (g)
             (cons (car g) (agents-hud--sort-entries (cdr g))))
           groups))
    (sort groups
          (lambda (a b)
            (let ((pa (agents-hud--entry-priority (cadr a)))
                  (pb (agents-hud--entry-priority (cadr b))))
              (if (/= pa pb)
                  (< pa pb)
                (string< (or (car a) "") (or (car b) ""))))))))

;;; ── Formatting (pure) ────────────────────────────────────────────────────────

(defun agents-hud--state-icon (state)
  "Return the icon string for STATE."
  (pcase state
    ('working agents-hud-working-icon)
    ('waiting agents-hud-waiting-icon)
    ('idle agents-hud-idle-icon)
    ('dead agents-hud-dead-icon)
    (_ "?")))

(defun agents-hud--state-face (state)
  "Return the face for STATE."
  (pcase state
    ('working 'agents-hud-working-face)
    ('waiting 'agents-hud-waiting-face)
    ('idle 'agents-hud-idle-face)
    ('dead 'agents-hud-dead-face)
    (_ 'default)))

(defun agents-hud--type-glyph (type)
  "Return the subtle plain-text leading glyph for buffer TYPE."
  (if (eq type 'claude)
      agents-hud-claude-glyph
    agents-hud-shell-glyph))

(defun agents-hud--type-icon (type)
  "Return a rich type icon for TYPE: a sparkle for Claude, a terminal for a shell.
Uses nerd-icons when available (matching the rest of the config), falling back
to the plain `agents-hud--type-glyph' when it is not, or if the glyph lookup
fails."
  (or (ignore-errors
        (pcase type
          ('claude
           (when (fboundp 'nerd-icons-mdicon)
             (nerd-icons-mdicon
              agents-hud-claude-icon
              :face 'nerd-icons-lpurple)))
          (_
           (when (fboundp 'nerd-icons-faicon)
             (nerd-icons-faicon
              agents-hud-shell-icon
              :face 'nerd-icons-green)))))
      (agents-hud--type-glyph type)))

(defun agents-hud--nerd-icon-for-buffer (orig &rest args)
  "Around advice for `nerd-icons-icon-for-buffer'.
Gives a `*claude:*' buffer the Claude glyph and any other `ghostel-mode' buffer
the shell glyph — so completion UIs (consult-buffer, the picker, ibuffer …) tell
Claude sessions from shells apart, which they cannot do from the shared
`ghostel-mode' alone.  Every other buffer falls through to ORIG unchanged."
  (cond
   ((string-prefix-p "*claude:" (buffer-name))
    (or (ignore-errors
          (apply #'nerd-icons-mdicon
                 agents-hud-claude-icon
                 :face
                 'nerd-icons-lpurple
                 args))
        (apply orig args)))
   ((derived-mode-p 'ghostel-mode)
    (or (ignore-errors
          (apply #'nerd-icons-faicon
                 agents-hud-shell-icon
                 :face
                 'nerd-icons-green
                 args))
        (apply orig args)))
   (t
    (apply orig args))))

(defun agents-hud--state-label (state)
  "Return the bare state word for STATE (\"exited\" for dead)."
  (pcase state
    ('dead "exited")
    (_ (symbol-name state))))

(defun agents-hud--status-label (entry)
  "Return ENTRY's status word, with the exit code appended for a dead buffer.
No timing — the state word alone (e.g. \"working\", \"exited (1)\")."
  (let ((state (agents-hud-entry-state entry))
        (exit (agents-hud-entry-exit entry)))
    (if (and (eq state 'dead) exit)
        (format "exited (%d)" exit)
      (agents-hud--state-label state))))

(defun agents-hud--sidebar-status (entry)
  "Return the trailing status column for ENTRY in the sidebar.
Empty by default (the leading icon carries the state); the full word appears
when `agents-hud-show-state-label' is on.  A dead buffer's exit code is shown
either way, since no icon can convey it."
  (let ((state (agents-hud-entry-state entry))
        (exit (agents-hud-entry-exit entry)))
    (cond
     (agents-hud-show-state-label
      (agents-hud--status-label entry))
     ((and (eq state 'dead) exit)
      (format "(%d)" exit))
     (t
      ""))))

;;; ── Sidebar ──────────────────────────────────────────────────────────────────

(defconst agents-hud--buffer-name "*agents-hud*"
  "Name of the sidebar buffer.")

(defvar agents-hud--timer nil
  "Repeating refresh timer, live only while the sidebar is shown.")

(defvar-keymap agents-hud-mode-map
  :doc
  "Keymap for `agents-hud-mode'."
  "RET"
  #'agents-hud-jump
  "SPC"
  #'agents-hud-peek
  "k"
  #'agents-hud-kill
  "c"
  #'agents-hud-new-claude
  "v"
  #'agents-hud-new-ghostel
  "g"
  #'agents-hud-refresh
  "n"
  #'agents-hud-next
  "p"
  #'agents-hud-prev
  "."
  #'agents-hud-avy
  "q"
  #'quit-window)

(define-derived-mode
 agents-hud-mode
 special-mode
 "Agents-HUD"
 "Major mode for the Claude/ghostel status sidebar."
 (setq-local cursor-type nil)
 (setq-local truncate-lines t)
 (buffer-disable-undo)
 (hl-line-mode 1))

(defun agents-hud--get-buffer ()
  "Return the sidebar buffer, creating and initialising it if needed."
  (let ((buf (get-buffer-create agents-hud--buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'agents-hud-mode)
        (agents-hud-mode)))
    buf))

(defun agents-hud--insert-entry (entry _now)
  "Insert one row for ENTRY, tagged with the entry for actions.
The leading state icon carries the status; the type icon (robot/terminal)
distinguishes a Claude session from a plain shell.  The status word only
appears when `agents-hud-show-state-label' is on (a dead exit code always does)."
  (let* ((state (agents-hud-entry-state entry))
         (face (agents-hud--state-face state))
         (icon (agents-hud--state-icon state))
         (tyicon
          (agents-hud--type-icon (agents-hud-entry-type entry)))
         (label (agents-hud--entry-label entry t))
         (status (agents-hud--sidebar-status entry))
         (path (agents-hud-entry-path entry))
         (start (point)))
    (insert
     "  "
     (propertize icon 'face face)
     " "
     tyicon
     " "
     (propertize label 'face face))
    (unless (string-empty-p status)
      (insert "  " (propertize status 'face face)))
    (insert
     "\n      " (propertize path 'face 'agents-hud-path-face) "\n")
    (put-text-property start (point) 'agents-hud-entry entry)))

(defun agents-hud--render ()
  "Re-render the sidebar buffer from a fresh entry snapshot."
  (with-demoted-errors "agents-hud render: %S"
    (let ((buf (get-buffer agents-hud--buffer-name)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (let* ((now (float-time))
                 (groups
                  (agents-hud--group-by-project
                   (agents-hud--entries now)))
                 (line (line-number-at-pos))
                 (inhibit-read-only t))
            (erase-buffer)
            (insert
             (propertize "Agents & terminals\n"
                         'face
                         'agents-hud-heading-face))
            (insert
             (make-string (max 1 (- agents-hud-width 2)) ?─) "\n")
            (if (null groups)
                (insert "\n  (no live sessions)\n")
              (dolist (g groups)
                (let*
                    ((key (car g))
                     (heading
                      (if key
                          (file-name-nondirectory
                           (directory-file-name key))
                        "No project"))
                     ;; Rows are attention-sorted, so the first is the
                     ;; highest-priority; only a genuine waiting session
                     ;; (priority 0) earns the ‹needs you› marker — a merely
                     ;; working group still floats up but is not flagged.
                     (needs
                      (= (agents-hud--entry-priority (cadr g)) 0)))
                  (insert
                   "\n"
                   (propertize (format "── %s%s"
                                       heading
                                       (if needs
                                           "  ‹needs you›"
                                         ""))
                               'face 'agents-hud-heading-face)
                   "\n")
                  (dolist (e (cdr g))
                    (agents-hud--insert-entry e now)))))
            (goto-char (point-min))
            (forward-line (1- line))))))))

;;;###autoload
(defun agents-hud-refresh ()
  "Refresh the sidebar now (also used as the `g' command).
Clears the worktree→repo cache so an explicit refresh re-resolves grouping."
  (interactive)
  (clrhash agents-hud--repo-root-cache)
  (clrhash agents-hud--worktree-cache)
  (agents-hud--get-buffer)
  (agents-hud--render))

(defun agents-hud--tick ()
  "Timer callback: re-render while the sidebar is visible, else stop."
  (if (get-buffer-window agents-hud--buffer-name)
      (agents-hud--render)
    (agents-hud--stop-timer)))

(defun agents-hud--start-timer ()
  "Start the repeating refresh timer if not already running."
  (unless (timerp agents-hud--timer)
    (setq agents-hud--timer
          (run-at-time
           agents-hud-refresh-interval
           agents-hud-refresh-interval
           #'agents-hud--tick))))

(defun agents-hud--stop-timer ()
  "Stop the repeating refresh timer."
  (when (timerp agents-hud--timer)
    (cancel-timer agents-hud--timer))
  (setq agents-hud--timer nil))

;;;###autoload
(defun agents-hud-toggle-sidebar ()
  "Toggle the Claude/ghostel status sidebar on the configured side."
  (interactive)
  (let* ((buf (agents-hud--get-buffer))
         (win (get-buffer-window buf)))
    (if (window-live-p win)
        (progn
          (agents-hud--stop-timer)
          (delete-window win))
      (agents-hud-refresh)
      (display-buffer-in-side-window
       buf
       `((side . ,agents-hud-side)
         (slot . 0)
         (window-width . ,agents-hud-width)
         (dedicated . t)
         (window-parameters . ((no-delete-other-windows . t)))))
      (agents-hud--start-timer))))

;;; ── Sidebar actions ──────────────────────────────────────────────────────────

(defun agents-hud--entry-at-point ()
  "Return the entry on the current sidebar line, or nil."
  (get-text-property (point) 'agents-hud-entry))

(defun agents-hud--main-window ()
  "Return the widest window to show a buffer in — never a side window.
Explicitly excludes the HUD sidebar and any other `window-side' window, so it
is correct whether called from the panel (RET) or from a code window (avy)."
  (let* ((cands
          (seq-remove
           (lambda (w)
             (window-parameter w 'window-side))
           (window-list nil 'no-mini))))
    (or (car
         (sort cands
               (lambda (a b) (> (window-width a) (window-width b)))))
        (get-mru-window nil nil 'not-selected) (selected-window))))

(defun agents-hud--goto-buffer (buf)
  "Switch to BUF in the main window (never the sidebar); keep the panel open."
  (if (buffer-live-p buf)
      (let ((win (agents-hud--main-window)))
        (if (window-live-p win)
            (progn
              (select-window win)
              (switch-to-buffer buf))
          (pop-to-buffer buf)))
    (message "agents-hud: buffer no longer live")))

(defun agents-hud-jump ()
  "Switch to the buffer on the current line in the main window; keep the panel."
  (interactive)
  (when-let* ((entry (agents-hud--entry-at-point)))
    (agents-hud--goto-buffer (agents-hud-entry-buffer entry))))

(defun agents-hud-peek ()
  "Show the current line's buffer in the main window without leaving the panel."
  (interactive)
  (when-let* ((entry (agents-hud--entry-at-point))
              (buf (agents-hud-entry-buffer entry))
              (win
               (and (buffer-live-p buf) (agents-hud--main-window))))
    (when (window-live-p win)
      (set-window-buffer win buf))))

;;; ── avy quick-select ─────────────────────────────────────────────────────────

(defun agents-hud--entry-positions (buffer)
  "Return the positions that start each session row in BUFFER."
  (with-current-buffer buffer
    (let ((pos (point-min))
          result)
      (when (get-text-property pos 'agents-hud-entry)
        (push pos result))
      (while (setq pos
                   (next-single-property-change
                    pos 'agents-hud-entry))
        (when (get-text-property pos 'agents-hud-entry)
          (push pos result)))
      (nreverse result))))

(defun agents-hud--avy-action (pt)
  "avy action: jump to the session whose row starts at PT in the sidebar.
PT is a position in the HUD buffer, so the entry is read there directly —
independent of which window avy leaves selected."
  (when-let* ((buf (get-buffer agents-hud--buffer-name))
              (entry
               (with-current-buffer buf
                 (get-text-property pt 'agents-hud-entry))))
    (agents-hud--goto-buffer (agents-hud-entry-buffer entry)))
  t)

;;;###autoload
(defun agents-hud-avy ()
  "Pick a session with avy: label every visible HUD row, jump on the keypress.
Works from any window while the sidebar is open — no need to focus it first."
  (interactive)
  (unless (require 'avy nil t)
    (user-error "agents-hud: avy is not available"))
  (let ((win (get-buffer-window agents-hud--buffer-name)))
    (unless (window-live-p win)
      (user-error "agents-hud: sidebar is not open (C-x C-a)"))
    (let ((cands
           (mapcar
            (lambda (pos) (cons pos win))
            (agents-hud--entry-positions (window-buffer win)))))
      (unless cands
        (user-error "agents-hud: no sessions to pick"))
      ;; Bind avy-action to our jumper (avy-process reads it); avy-keys keep
      ;; their global default, so no `avy-with' macro (hence no compile-time
      ;; dependency on avy) is needed.
      (let ((avy-action #'agents-hud--avy-action))
        (avy-process cands)))))

(defun agents-hud-kill ()
  "Kill the buffer/process on the current line (with confirmation)."
  (interactive)
  (when-let* ((entry (agents-hud--entry-at-point))
              (buf (agents-hud-entry-buffer entry)))
    (when (and (buffer-live-p buf)
               (yes-or-no-p (format "Kill %s? " (buffer-name buf))))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buf))
      (agents-hud-refresh))))

(defun agents-hud--read-project ()
  "Prompt for a project directory to launch in; default to the current one."
  (if (fboundp 'project-prompt-project-dir)
      (project-prompt-project-dir)
    (read-directory-name "Directory: ")))

(defun agents-hud-new-claude ()
  "Start a new Claude session in a chosen project, shown in the main window."
  (interactive)
  (unless (fboundp 'claude-code)
    (user-error "claude-code is not available"))
  (let ((dir (agents-hud--read-project))
        (win (agents-hud--main-window)))
    (when (window-live-p win)
      (select-window win))
    (let ((default-directory dir))
      (claude-code))))

(defun agents-hud-new-ghostel ()
  "Start a new ghostel terminal in a chosen project, in the main window."
  (interactive)
  (let ((dir (agents-hud--read-project))
        (win (agents-hud--main-window)))
    (when (window-live-p win)
      (select-window win))
    (let ((default-directory dir))
      (cond
       ((fboundp 'ghostel-project)
        (ghostel-project))
       ((fboundp 'ghostel)
        (ghostel))
       (t
        (user-error "ghostel is not available"))))))

(defun agents-hud--goto-entry (dir)
  "Move to the next (DIR = 1) or previous (DIR = -1) row bearing an entry."
  (let ((target nil)
        (pos (point)))
    (save-excursion
      (forward-line dir)
      (while (and (not (bobp)) (not (eobp)) (not target))
        (when (agents-hud--entry-at-point)
          (setq target (line-beginning-position)))
        (forward-line dir)))
    (when (and (not target) (agents-hud--entry-at-point))
      (setq target pos))
    (when target
      (goto-char target))))

(defun agents-hud-next ()
  "Move to the next session row."
  (interactive)
  (agents-hud--goto-entry 1))

(defun agents-hud-prev ()
  "Move to the previous session row."
  (interactive)
  (agents-hud--goto-entry -1))

;;; ── Consult group (picker) ───────────────────────────────────────────────────

;; Candidates are plain buffer names with `category 'buffer', so consult's own
;; buffer preview / switching work unchanged.  The per-type icon (Claude vs
;; shell) comes from the `nerd-icons-icon-for-buffer' advice installed by
;; `agents-hud-setup' — which fixes the icon everywhere a buffer icon is drawn
;; (consult-buffer's Agents group, this picker, ibuffer), not just here.

(defun agents-hud--consult-candidates ()
  "Return live Claude/ghostel buffer names, attention-sorted, for consult."
  (mapcar
   (lambda (e) (buffer-name (agents-hud-entry-buffer e)))
   (agents-hud--sort-entries (agents-hud--entries))))

(defun agents-hud--consult-annotate (cand)
  "Annotate consult candidate CAND (a buffer name) with status, project, path."
  (when-let ((buf (get-buffer cand)))
    (let* ((entry (agents-hud--entry buf))
           (state (agents-hud-entry-state entry)))
      (concat
       (propertize (format "  %-2s %-9s"
                           (agents-hud--state-icon state)
                           (agents-hud--status-label entry))
                   'face (agents-hud--state-face state))
       (propertize (format " %-16s" (agents-hud--entry-label entry))
                   'face 'default)
       (propertize (format " %s" (agents-hud-entry-path entry))
                   'face
                   'agents-hud-path-face)))))

;;;###autoload
(defvar agents-hud-consult-source
  (list
   :name "Agents"
   :category 'buffer
   :narrow ?a
   :face 'consult-buffer
   :history 'buffer-name-history
   :annotate #'agents-hud--consult-annotate
   :state
   (lambda ()
     (when (fboundp 'consult--buffer-state)
       (consult--buffer-state)))
   :action #'switch-to-buffer
   :items #'agents-hud--consult-candidates)
  "`consult-buffer' source listing Claude/ghostel buffers with live status.
Add to `consult-buffer-sources' to fold it in as a narrowable group (`a'), or
open it directly with `agents-hud-picker'.  Per-type icons come from the
`nerd-icons-icon-for-buffer' advice in `agents-hud-setup'.")

;;;###autoload
(defun agents-hud-picker ()
  "Pick a Claude/ghostel buffer from the attention-sorted Agents group."
  (interactive)
  (unless (fboundp 'consult--multi)
    (user-error "consult is not available"))
  (consult--multi
   (list agents-hud-consult-source)
   :prompt "Agent: "
   :require-match t
   :sort nil))

(provide 'agents-hud)
;;; agents-hud.el ends here
