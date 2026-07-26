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
;;     grouped by project, that live-updates on a timer.  Each row leads with a
;;     status icon and then stacks three aligned lines: the session name, its
;;     git branch, and its working directory.  WAITING rows float to the top of
;;     their group and groups with a waiting/working session sort first, so what
;;     needs you is always near the top.  A project heading folds shut with TAB
;;     (or RET on the heading); a folded group still shows its count and its
;;     ‹needs you› marker.
;;
;;   * `agents-hud-consult-source' / `agents-hud-picker' (C-c c b) — the same
;;     buffers as a narrowable consult group (folded into `consult-buffer', or
;;     opened directly), attention-sorted, with `SPC' preview.
;;
;; STATUS MODEL (per buffer), four states:
;;
;;   ⠋ working — the terminal is churning: either ghostel's own OSC-133
;;               `ghostel--command-running' flag is set (a shell command is
;;               running) or a redraw fired within `agents-hud-idle-seconds'.
;;               Shown as a spinner (`agents-hud-working-frames') animated in
;;               place by a fast timer (`agents-hud-spinner-interval').  A redraw
;;               caused purely by you (a focus event from looking at the buffer,
;;               or a keystroke echo) is discounted — see
;;               `agents-hud-interaction-grace'.
;;   ◆ waiting — Claude is BLOCKED on a selection prompt and needs you to
;;               choose: a permission dialog, plan approval, the shift-tab mode
;;               menu.  Detected from the live screen (see
;;               `agents-hud--selection-prompt-p') — the numbered-option picker
;;               with its `❯ N.' caret and `Enter to select …' footer — NOT the
;;               end-of-turn bell, which fires every turn and would flag every
;;               finished session as needing you.
;;   ● ready   — a live process, not working and not at a selection prompt:
;;               standing by for input.  A Claude session that finished its turn
;;               and a shell idling at its prompt both land here.
;;   ✕ dead    — no live process (only visible if the buffer lingers;
;;               `ghostel-kill-buffer-on-exit' defaults to t, so exited
;;               terminals usually vanish rather than show here).
;;
;; The state-tracking side effects (activity stamp, exit code) are installed by
;; `agents-hud-setup', which is idempotent and degrades quietly when ghostel /
;; claude-code are absent.  What the two front-ends render is derived by pure
;; functions (`agents-hud--compute-state', `--sort-entries',
;; `--group-by-project', `--format-…') from those stamps plus a live read of the
;; screen for the waiting prompt — which is what the ERT suite exercises.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'project)

;; Soft dependencies — never `require'd, so the package (and its ERT suite)
;; loads with only built-ins present.  Guarded at every call site with
;; `fboundp' / `bound-and-true-p'.
(defvar consult-buffer-sources)
(declare-function claude-code "claude-code" (&optional arg))
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
(declare-function file-notify-valid-p "filenotify" (descriptor))
(defvar avy-action)
(defvar avy-keys)
(defvar avy-style)

;;; ── Customization ────────────────────────────────────────────────────────────

(defgroup agents-hud nil
  "Live status view and switcher for Claude/ghostel buffers."
  :group 'convenience
  :prefix "agents-hud-")

(defcustom agents-hud-idle-seconds 3.0
  "Seconds of terminal quiet after which a working buffer stops counting as busy.
A redraw within this window counts the buffer as working (the spinner); once
redraws stop for this long (and no shell command is running) it drops to ●
ready."
  :type 'number)

(defcustom agents-hud-refresh-interval 1.0
  "Seconds between automatic sidebar re-renders while the panel is visible.
The tick also advances the displayed durations and flips working→ready."
  :type 'number)

(defcustom agents-hud-spinner-interval 0.1
  "Seconds between working-spinner frames while the panel is visible.
A faster, lighter timer than the full re-render: it rewrites only the spinner
glyph in place, so the animation is smooth without re-rendering the buffer."
  :type 'number)

(defcustom agents-hud-selection-prompt-regexp
  "Enter to select\\|Tab/Arrow keys to navigate\\|❯ *[0-9]+\\."
  "Regexp marking a Claude Code selection prompt on a terminal's live screen.
When it matches the bottom of a session (the last
`agents-hud-selection-scan-lines' lines) the session is ◆ waiting — Claude is
blocked on a choice you must make.  The default matches the picker's `Enter to
select …' / `Tab/Arrow keys to navigate' footer and its `❯ N.' selected-option
caret (the idle input box shows `❯' followed by placeholder text, never a
number, so it does not match).  Retune if the CLI's prompt UI changes."
  :type 'regexp)

(defcustom agents-hud-selection-scan-lines 20
  "How many trailing lines of a terminal to scan for a selection prompt.
Kept small so only the live screen is searched: a prompt you already answered,
scrolled up into scrollback, does not linger as a false ◆ waiting."
  :type 'integer)

(defcustom agents-hud-interaction-grace 0.4
  "Seconds after a user interaction during which a redraw is not counted as work.
A terminal redraw can be caused by you rather than by Claude: switching into or
out of a buffer makes ghostel send a focus event (DEC mode 1004) that a
focus-reporting TUI repaints in response, and typing echoes each keystroke back.
Both are ordinary redraws indistinguishable from real output.  A redraw on an
otherwise-quiet buffer within this window of an interaction — a focus change
\(on EITHER side, as its repaint can fire just before or just after the focus
hook) or a keystroke — is ignored, so merely looking at or typing into a parked
session no longer flips it to the working spinner.  A buffer that is already
active keeps stamping normally, so genuine work is never suppressed.  Set to 0
to disable."
  :type 'number)

(defcustom agents-hud-avy-keys-style 'letters
  "Which keys `agents-hud-avy' labels session rows with, top to bottom.
`letters' walks a, b, c … z (the default); `numbers' walks 1, 2, 3 … 9, 0.
Either way the labels run in row order, so the first visible session is always
the first key."
  :type
  '(choice
    (const :tag "Letters (a b c …)" letters)
    (const :tag "Numbers (1 2 3 …)" numbers)))

(defcustom agents-hud-side 'right
  "Side of the frame the sidebar window opens on."
  :type '(choice (const left) (const right)))

(defcustom agents-hud-width 36
  "Width in columns of the sidebar window."
  :type 'integer)

(defcustom agents-hud-working-frames
  '("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  "Frames cycled for the working spinner (see `agents-hud-spinner-interval').
The default is the braille-dot spinner familiar from modern CLIs.  Any list of
strings works — the `progress-reporter' pulse \\='(\"-\" \"\\\\\" \"|\" \"/\"), clock
faces \\='(\"🕐\" \"🕑\" …), moon phases — and each row pads its icon to a fixed
width, so frames of any width stay aligned.  Set to nil for a static
`agents-hud-working-icon' instead."
  :type '(repeat string))

(defcustom agents-hud-working-icon "🤔"
  "Static icon for the working state, used when `agents-hud-working-frames' is nil."
  :type 'string)

(defcustom agents-hud-waiting-icon "◆"
  "Icon for the ◆ waiting-on-you state.
A single-width diamond tinted amber by `agents-hud-waiting-face' — the attention
mark in the same mono-glyph family as the ● ready dot and the working spinner."
  :type 'string)

(defcustom agents-hud-ready-icon "●"
  "Icon for the ● ready state (live, quiet, standing by for input).
A plain text circle tinted green by `agents-hud-ready-face' — the same
mono-glyph-coloured-by-face style as the working spinner, and the universal
\"online / available\" green dot."
  :type 'string)

(defcustom agents-hud-dead-icon "✕"
  "Icon for the ✕ dead state.
A single-width cross tinted grey by `agents-hud-dead-face', in the same
mono-glyph family as the other state icons."
  :type 'string)

(defcustom agents-hud-expanded-icon "▾"
  "Leading glyph on an expanded (open) project group heading."
  :type 'string)

(defcustom agents-hud-collapsed-icon "▸"
  "Leading glyph on a collapsed (folded) project group heading."
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
  "When non-nil, spell out the state word (working/ready/…) in the sidebar.
Off by default: the leading state icon (spinner, ◆, ●, ✕) carries the status
and the row stays compact.  A dead buffer's exit code is shown either way."
  :type 'boolean)

;; The four state faces make a distinct blue/amber/green/grey palette.  They
;; inherit standard semantic faces (`link'/`warning'/`success'/`shadow'), so the
;; colours come from whatever theme is active — no theme-specific wiring — and
;; follow along automatically when you switch themes.

(defface agents-hud-working-face
  '((t :inherit link :underline nil :weight normal))
  "Face for the working spinner icon and status text.
Blue (via `link', underline stripped) — \"in progress\", distinct from the amber
attention state.  Tints the monochrome spinner glyph.")

(defface agents-hud-waiting-face '((t :inherit warning :weight bold))
  "Face for the waiting-on-you state icon and status text.
Amber (via `warning') and bold: the attention state — Claude is blocked on a
choice you must make — warm and prominent against the calm green ready dot.
Tints the ◆ glyph, which carries no colour of its own.")

(defface agents-hud-ready-face '((t :inherit success))
  "Face for the ready state icon and status text.
Green (via `success'): a session standing by, ready for input — the \"online /
available\" dot.  Tints the ● glyph, which carries no colour of its own.")

(defface agents-hud-dead-face '((t :inherit shadow))
  "Face for the dead state icon and status text.
Dimmed grey (via `shadow'): an exited process, faded out.  Tints the ✕ glyph.")

(defface agents-hud-heading-face '((t :inherit bold))
  "Face for project group headings in the sidebar.")

(defface agents-hud-path-face '((t :inherit font-lock-comment-face))
  "Face for the working-directory path in a row.")

(defface agents-hud-branch-face '((t :inherit font-lock-string-face))
  "Face for the git-branch line in a row.
Distinct from `agents-hud-path-face' so the branch and the working directory,
stacked under the session name, read as two different things at a glance.")

;;; ── State tracking (buffer-local stamps) ─────────────────────────────────────

(defvar-local agents-hud--activity nil
  "`float-time' of this buffer's last terminal redraw, or nil.")

(defvar-local agents-hud--activity-prev nil
  "The `agents-hud--activity' value from before the most recent stamp.
Kept so `agents-hud--note-focus-change' can roll back a display/focus repaint
that stamped a quiet buffer a few milliseconds before the focus hook fired.")

(defvar-local agents-hud--working-since nil
  "`float-time' the current active burst began, for the working duration.")

(defvar-local agents-hud--exit nil
  "Exit code recorded when this buffer's terminal process exited, or nil.")

(defvar-local agents-hud--input-time nil
  "`float-time' of the last explicit user keystroke into this buffer, or nil.
Stamped by `agents-hud--note-input' (advising `ghostel--on-user-input'); lets
`agents-hud--note-activity' discount the echo repaint typing produces so a
session you are replying to is not mistaken for one that is working.")

(defvar agents-hud--focus-change-time nil
  "`float-time' of the most recent terminal focus change (any buffer), or nil.
Global, not buffer-local: `ghostel--focus-change' fires for whichever buffers
just gained or lost focus, so a single stamp covers the repaint that follows on
each of them.  Read by `agents-hud--interaction-suppressed-p'.")

(defun agents-hud--latest-time (&rest times)
  "Return the largest non-nil `float-time' in TIMES, or nil when all are nil."
  (let ((ts (delq nil times)))
    (and ts (apply #'max ts))))

(defun agents-hud--interaction-suppressed-p
    (now interaction-time activity grace cutoff)
  "Non-nil when a redraw at NOW should be ignored as a user-interaction repaint.
INTERACTION-TIME is the last focus change or keystroke; ACTIVITY the buffer's
last redraw; GRACE the interaction window (`agents-hud-interaction-grace');
CUTOFF the quiet threshold (`agents-hud-idle-seconds').  Swallowed only when an
interaction landed within GRACE AND the buffer was quiet (no ACTIVITY within
CUTOFF) — i.e. this lone redraw (a focus repaint, or a keystroke echo) would
spuriously flip a parked session to working.  An already-active buffer (fresh
ACTIVITY) is never suppressed, so genuine work is never starved."
  (and interaction-time
       grace
       (> grace 0)
       (< (- now interaction-time) grace)
       (or (null activity) (>= (- now activity) cutoff))))

(defun agents-hud--focus-rollback-p
    (now activity activity-prev grace cutoff)
  "Non-nil when ACTIVITY is a focus-repaint stamp to undo after a focus change.
The repaint that paints a newly-shown buffer can land a few milliseconds BEFORE
`ghostel--focus-change' updates the focus stamp, so the forward guard
\(`agents-hud--interaction-suppressed-p') misses it.  On the focus change,
undo the stamp if the buffer's last redraw landed within GRACE of NOW AND it was
a quiet→active flip (ACTIVITY-PREV absent or older than CUTOFF before it).  A
genuinely working buffer re-stamps on its next redraw, so a wrong rollback
self-heals in one frame; a lone focus repaint stays rolled back."
  (and activity
       grace (> grace 0) (< (- now activity) grace)
       (or (null activity-prev)
           (>= (- activity activity-prev) cutoff))))

(defun agents-hud--note-activity (buffer)
  "Stamp BUFFER's last-activity time on a redraw; never inhibit the redraw.
For `ghostel-inhibit-redraw-functions' (called with BUFFER current before each
redraw): returns nil so the redraw always proceeds.  When activity resumes
after a quiet spell it also restarts `agents-hud--working-since' so the working
duration measures the current burst, not the whole session.

A redraw that is merely a user-interaction repaint on a quiet buffer is ignored,
so looking at or typing into a parked session does not flash it as working — see
`agents-hud-interaction-grace'.  The focus case is bracketed: a focus change
just BEFORE the redraw suppresses it here
\(`agents-hud--interaction-suppressed-p'); one just AFTER rolls it back
\(`agents-hud--note-focus-change'), which is why the prior activity is kept in
`agents-hud--activity-prev'.  A keystroke is stamped before its echo, so the
forward guard alone covers typing."
  (with-demoted-errors "agents-hud activity: %S"
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((now (float-time)))
          (unless (agents-hud--interaction-suppressed-p
                   now
                   (agents-hud--latest-time
                    agents-hud--focus-change-time
                    agents-hud--input-time)
                   agents-hud--activity
                   agents-hud-interaction-grace
                   agents-hud-idle-seconds)
            (when (or (null agents-hud--activity)
                      (>= (- now agents-hud--activity)
                          agents-hud-idle-seconds))
              (setq agents-hud--working-since now))
            (setq agents-hud--activity-prev agents-hud--activity)
            (setq agents-hud--activity now))))))
  nil)

(defun agents-hud--note-focus-change (&rest _)
  "Record a terminal focus change and undo any repaint it triggered just before.
For `:after' advice on `ghostel--focus-change' (which sends the DEC mode 1004
focus events).  Stamps `agents-hud--focus-change-time', so a repaint landing
just AFTER is discounted by `agents-hud--note-activity'.  Then rolls back any
quiet buffer whose last redraw landed just BEFORE this hook: the repaint that
paints a newly-shown buffer fires a few ms ahead of the focus hook, which the
forward guard cannot catch (`agents-hud--focus-rollback-p')."
  (with-demoted-errors "agents-hud focus: %S"
    (let ((now (float-time)))
      (setq agents-hud--focus-change-time now)
      (dolist (b (agents-hud--buffers))
        (with-current-buffer b
          (when (agents-hud--focus-rollback-p
                 now
                 agents-hud--activity
                 agents-hud--activity-prev
                 agents-hud-interaction-grace
                 agents-hud-idle-seconds)
            (setq agents-hud--activity
                  agents-hud--activity-prev)))))))

(defun agents-hud--note-input (&rest _)
  "Stamp `agents-hud--input-time' when the user sends a keystroke to a terminal.
For `:before' advice on `ghostel--on-user-input', which runs in the terminal
buffer just before the key reaches the PTY — hence before the echo repaint, so
`agents-hud--note-activity' discounts that repaint and typing a reply does not
read as Claude working."
  (with-demoted-errors "agents-hud input: %S"
    (setq agents-hud--input-time (float-time))))

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
Wires redraw-activity stamping and exit recording on ghostel, the
focus/keystroke interaction guards, and per-type completion icons on nerd-icons.
Safe to call when those packages are not yet loaded; the pieces attach as they
load.  Waiting is read from the live screen at render time
\(`agents-hud--selection-prompt-p'), so it needs no hook here."
  (interactive)
  (unless agents-hud--setup-done
    (with-eval-after-load 'ghostel
      (add-hook
       'ghostel-inhibit-redraw-functions #'agents-hud--note-activity)
      (add-hook 'ghostel-exit-functions #'agents-hud--note-exit)
      ;; Discount redraws you cause rather than Claude: the repaint a
      ;; focus-reporting TUI makes on focus in/out, and the echo of your own
      ;; keystrokes, so looking at or typing into a parked session does not
      ;; flash it as working (see `agents-hud-interaction-grace').
      (when (fboundp 'ghostel--focus-change)
        (advice-add
         'ghostel--focus-change
         :after #'agents-hud--note-focus-change))
      (when (fboundp 'ghostel--on-user-input)
        (advice-add
         'ghostel--on-user-input
         :before #'agents-hud--note-input)))
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

(defvar agents-hud--branch-cache (make-hash-table :test 'equal)
  "Memoises `agents-hud--branch' per directory (\\='none = detached/no branch).
Cleared with the other git caches on `agents-hud-refresh'.")

(defun agents-hud--branch (dir)
  "Return the git branch checked out in DIR's worktree, or nil.
Unlike `agents-hud--worktree-tag' this is the real branch for EVERY worktree,
not the directory basename of a linked one.  A detached HEAD yields nil."
  (when (and dir (file-directory-p dir))
    (let* ((key (directory-file-name (expand-file-name dir)))
           (cached (gethash key agents-hud--branch-cache 'miss)))
      (if (not (eq cached 'miss))
          (unless (eq cached 'none)
            cached)
        (let* ((br
                (agents-hud--git key
                                 "rev-parse"
                                 "--abbrev-ref"
                                 "HEAD"))
               (val (and br (not (string= br "HEAD")) br)))
          (puthash key (or val 'none) agents-hud--branch-cache)
          val)))))

;; A branch switch made outside Emacs (a shell `git checkout') leaves the branch
;; cache stale until the next explicit `agents-hud-refresh'.  No in-Emacs hook
;; sees an external switch, but the filesystem does: a switch rewrites the git
;; dir's HEAD symref (a plain commit does NOT — it moves refs/heads/…, HEAD stays
;; put), so a `file-notify' watch on the git dir catches switches with no noise.
;; When HEAD changes we drop the branch/worktree caches; the next render
;; re-resolves.  Watching the DIRECTORY (not the HEAD file) survives git's
;; atomic HEAD.lock→HEAD rename.

(defvar agents-hud--gitdir-cache (make-hash-table :test 'equal)
  "Memoises a directory's absolute git dir (\\='none = not a repo).")

(defun agents-hud--gitdir (dir)
  "Return the absolute git dir governing DIR (the linked worktree's own), or nil."
  (when (and dir (file-directory-p dir))
    (let* ((key (directory-file-name (expand-file-name dir)))
           (cached (gethash key agents-hud--gitdir-cache 'miss)))
      (if (not (eq cached 'miss))
          (unless (eq cached 'none)
            cached)
        (let* ((gd
                (agents-hud--git key
                                 "rev-parse"
                                 "--absolute-git-dir"))
               (val (and gd (file-directory-p gd) gd)))
          (puthash key (or val 'none) agents-hud--gitdir-cache)
          val)))))

(defvar agents-hud--head-watches (make-hash-table :test 'equal)
  "Maps a watched git dir to its `file-notify' descriptor (or \\='failed).")

(defun agents-hud--on-head-change (event)
  "`file-notify' callback: drop the branch/worktree caches when a HEAD changes.
EVENT is (DESCRIPTOR ACTION FILE …).  Only a change to a file named HEAD counts
\(a branch switch); the git dir's other churn — index, logs, ref locks — is
ignored.  git's atomic HEAD.lock→HEAD rename can then stop this watch;
`agents-hud--watch-head' re-arms a stopped watch on the next render."
  (with-demoted-errors "agents-hud head-watch: %S"
    (when (and (memq (nth 1 event) '(changed created renamed))
               (equal
                (file-name-nondirectory (or (nth 2 event) ""))
                "HEAD"))
      (clrhash agents-hud--branch-cache)
      (clrhash agents-hud--worktree-cache))))

(defun agents-hud--watch-head (dir)
  "Ensure a live `file-notify' watch on DIR's git dir so switches self-refresh.
Re-arms if the prior watch is gone or was stopped (`file-notify-valid-p') —
git's HEAD rewrite can stop it — so each render (≤1s) keeps it armed.  Cheap
once set up (a cached git-dir lookup, then a validity check); silently does
nothing without `file-notify' or outside a repo."
  (when (fboundp 'file-notify-add-watch)
    (when-let ((gitdir (agents-hud--gitdir dir)))
      (let ((cur (gethash gitdir agents-hud--head-watches)))
        (unless (and cur
                     (not (eq cur 'failed))
                     (ignore-errors
                       (file-notify-valid-p cur)))
          (puthash
           gitdir
           (condition-case nil
               (file-notify-add-watch
                gitdir '(change) #'agents-hud--on-head-change)
             (error
              'failed))
           agents-hud--head-watches))))))

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
 branch
 path
 instance
 state
 since
 exit)

(defun agents-hud--selection-prompt-p (buffer)
  "Non-nil when BUFFER's live screen shows a Claude Code selection prompt.
The picker Claude Code puts up when it is blocked on your choice — a permission
dialog, plan approval, the shift-tab mode menu — renders numbered options with a
`❯' caret and an `Enter to select …' footer.  That, not the end-of-turn bell, is
what ◆ waiting means: the bell fires every turn and would flag every finished
session.  Only the last `agents-hud-selection-scan-lines' lines (the live
screen) are searched, so a prompt already answered and scrolled up into history
does not count."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (save-excursion
        (goto-char (point-max))
        (forward-line (- agents-hud-selection-scan-lines))
        (and (re-search-forward agents-hud-selection-prompt-regexp
                                nil
                                t)
             t)))))

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
a selection prompt is on screen (Claude blocked on your choice).  ACTIVITY —
last redraw `float-time'.  Priority: dead → waiting → working → ready."
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
   'ready)))

(defun agents-hud--entry (buffer &optional now)
  "Build a `agents-hud-entry' snapshot for BUFFER at time NOW."
  (let* ((now (or now (float-time)))
         (type (agents-hud--buffer-type buffer))
         (proc (get-buffer-process buffer))
         (live (and proc (process-live-p proc)))
         (activity (buffer-local-value 'agents-hud--activity buffer))
         (working-since
          (buffer-local-value 'agents-hud--working-since buffer))
         (cmd-running
          (and (boundp 'ghostel--command-running)
               (buffer-local-value 'ghostel--command-running buffer)))
         (waiting (agents-hud--selection-prompt-p buffer))
         (state
          (agents-hud--compute-state
           :live live
           :cmd-running cmd-running
           :waiting waiting
           :activity activity
           :now now))
         (since
          (pcase state
            ('waiting (or activity now))
            ('working (or working-since activity now))
            ('ready (or activity now))
            (_ nil)))
         (dir (agents-hud--buffer-dir buffer))
         (project (agents-hud--buffer-project buffer)))
    ;; Watch this repo's HEAD so an external branch switch re-resolves on its
    ;; own (idempotent per git dir — see `agents-hud--watch-head').
    (agents-hud--watch-head dir)
    (agents-hud-entry--create
     :buffer buffer
     :type type
     :project project
     :worktree (agents-hud--worktree-tag dir project)
     :branch (agents-hud--branch dir)
     :path (agents-hud--buffer-path buffer)
     :instance
     (agents-hud--buffer-instance buffer type)
     :state state
     :since since
     :exit
     (buffer-local-value 'agents-hud--exit buffer))))

(defun agents-hud--entries (&optional now)
  "Return `agents-hud-entry' snapshots for all live Claude/ghostel buffers."
  (let ((now (or now (float-time))))
    (mapcar
     (lambda (b) (agents-hud--entry b now)) (agents-hud--buffers))))

;;; ── Sorting & grouping (pure) ────────────────────────────────────────────────

(defconst agents-hud--state-priority
  '((waiting . 0) (working . 1) (ready . 2) (dead . 3))
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

;; Stable ordering for the sidebar.  Rows must NOT reshuffle when a session
;; flips working↔ready↔waiting — position is tied to identity, not state.  Each
;; buffer gets a monotonically increasing "first-seen" sequence the first time
;; it is rendered; rows and groups are ordered by it, so a row keeps its slot
;; for life and only earlier removals shift it up.  (The transient consult
;; picker still uses the attention-first `agents-hud--sort-entries'.)
(defvar agents-hud--seq-counter 0
  "Monotonic counter handing out `agents-hud--seq' values.")

(defvar agents-hud--seq-table
  (make-hash-table :test 'eq :weakness 'key)
  "Maps a buffer to its stable first-seen sequence number.
Weak on the key so entries vanish when their buffer is garbage-collected.")

(defun agents-hud--seq (buffer)
  "Return BUFFER's stable first-seen sequence, assigning the next one if new."
  (or (gethash buffer agents-hud--seq-table)
      (puthash
       buffer
       (cl-incf agents-hud--seq-counter)
       agents-hud--seq-table)))

(defun agents-hud--stable-sort (entries)
  "Return ENTRIES ordered by stable first-seen sequence (ascending)."
  (sort (copy-sequence entries)
        (lambda (a b)
          (< (agents-hud--seq (agents-hud-entry-buffer a))
             (agents-hud--seq (agents-hud-entry-buffer b))))))

(defun agents-hud--group-by-project (entries)
  "Group ENTRIES by project into (GROUP-KEY . STABLE-ENTRIES) pairs.
Rows within a group and the groups themselves keep first-seen order, so a row
holds its position across state changes — only an earlier row (or group) being
removed shifts it.  A group's position is set by its earliest member."
  ;; Assign sequences up front, in the order ENTRIES arrive, so the first-seen
  ;; order is deterministic rather than however `sort' happens to compare.
  (dolist (e entries)
    (agents-hud--seq (agents-hud-entry-buffer e)))
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
             (cons (car g) (agents-hud--stable-sort (cdr g))))
           groups))
    ;; groups ordered by their earliest member (rows already ascending, so the
    ;; first entry carries the group's minimum sequence)
    (sort groups
          (lambda (a b)
            (< (agents-hud--seq (agents-hud-entry-buffer (cadr a)))
               (agents-hud--seq
                (agents-hud-entry-buffer (cadr b))))))))

;;; ── Formatting (pure) ────────────────────────────────────────────────────────

(defvar agents-hud--spinner-index 0
  "Counter advanced once per render to pick the working spinner frame.")

(defun agents-hud--working-icon ()
  "Return the working icon: the current spinner frame, else the static icon.
Frames come from `agents-hud-working-frames', advanced by
`agents-hud--spinner-index'; with no frames, `agents-hud-working-icon'."
  (if agents-hud-working-frames
      (nth
       (mod
        agents-hud--spinner-index (length agents-hud-working-frames))
       agents-hud-working-frames)
    agents-hud-working-icon))

(defun agents-hud--state-icon (state)
  "Return the icon string for STATE."
  (pcase state
    ('working (agents-hud--working-icon))
    ('waiting agents-hud-waiting-icon)
    ('ready agents-hud-ready-icon)
    ('dead agents-hud-dead-icon)
    (_ "?")))

(defun agents-hud--state-face (state)
  "Return the face for STATE."
  (pcase state
    ('working 'agents-hud-working-face)
    ('waiting 'agents-hud-waiting-face)
    ('ready 'agents-hud-ready-face)
    ('dead 'agents-hud-dead-face)
    (_ 'default)))


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

(defvar agents-hud--spinner-timer nil
  "Fast repeating timer that animates the working spinner, live with the panel.")

(defvar agents-hud--inhibit-render nil
  "When non-nil, the refresh tick skips re-rendering the sidebar.
Bound while `agents-hud-avy' waits for a keypress: the tick's `erase-buffer'
would otherwise wipe avy's label overlays mid-selection, so the hints vanish
after one interval even though the positions (and the jump) survive.")

(defvar-keymap agents-hud-mode-map
  :doc
  "Keymap for `agents-hud-mode'."
  "RET"
  #'agents-hud-jump
  "TAB"
  #'agents-hud-toggle-collapse
  "<tab>"
  #'agents-hud-toggle-collapse
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

(defun agents-hud--entry-name (entry)
  "Return the row's display name for ENTRY: its instance, else a sensible fallback.
For a Claude session this is the `:name' suffix (email, review, …); for a plain
shell its title.  Falls back to the worktree/branch, the repo, or the path's
basename so a nameless session still labels itself."
  (or (agents-hud-entry-instance entry)
      (agents-hud-entry-worktree entry)
      (agents-hud-entry-branch entry)
      (when-let ((p (agents-hud-entry-project entry)))
        (file-name-nondirectory p))
      (when-let ((p (agents-hud-entry-path entry)))
        (file-name-nondirectory p))
      "session"))

(defun agents-hud--insert-entry (entry _now)
  "Insert one row for ENTRY as three aligned lines: name, branch, working dir.
The leading state icon carries the status; the name, branch and pwd stack
vertically aligned beneath each other, the continuation lines indented to the
display width of the icon prefix so they line up with the name whatever the
icon's width.  The branch and pwd lines are omitted individually when unknown;
the status word only appears when `agents-hud-show-state-label' is on (a dead
exit code always does)."
  (let*
      ((state (agents-hud-entry-state entry))
       (face (agents-hud--state-face state))
       ;; Pad the icon to a fixed two columns so rows align whatever the
       ;; glyph's width — an emoji (2), or a single-width spinner frame.
       (icon
        (truncate-string-to-width
         (agents-hud--state-icon state) 2 0 ?\s))
       (name (agents-hud--entry-name entry))
       (branch (agents-hud-entry-branch entry))
       (status (agents-hud--sidebar-status entry))
       (path (agents-hud-entry-path entry))
       (indent
        (make-string (string-width (concat "  " icon " ")) ?\s))
       (start (point)))
    (insert
     "  "
     ;; Tag a working icon so `agents-hud--spin' can animate it in place.
     (propertize icon
                 'face
                 face
                 'agents-hud-spinner
                 (eq state 'working))
     " " (propertize name 'face face))
    (unless (string-empty-p status)
      (insert "  " (propertize status 'face face)))
    (insert "\n")
    (when branch
      (insert
       indent (propertize branch 'face 'agents-hud-branch-face) "\n"))
    (when path
      (insert
       indent (propertize path 'face 'agents-hud-path-face) "\n"))
    (put-text-property start (point) 'agents-hud-entry entry)))

(defvar agents-hud--collapsed (make-hash-table :test 'equal)
  "Set of project-group keys currently folded shut in the sidebar.
A key is the group's project root (else its path); presence = collapsed.
Global so the fold survives the timer's re-renders.")

(defun agents-hud--group-collapsed-p (key)
  "Non-nil when the project group KEY is folded shut."
  (and key (gethash key agents-hud--collapsed) t))

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
             (propertize "🤖 Agents\n" 'face 'agents-hud-heading-face))
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
                     (collapsed (agents-hud--group-collapsed-p key))
                     ;; Rows keep stable order, so scan the whole group: it
                     ;; earns the ‹needs you› marker when ANY member is a
                     ;; genuine waiting session (priority 0).
                     (needs
                      (seq-some
                       (lambda (e)
                         (= (agents-hud--entry-priority e) 0))
                       (cdr g))))
                  (insert
                   "\n"
                   (propertize (format "%s %s%s%s"
                                       (if collapsed
                                           agents-hud-collapsed-icon
                                         agents-hud-expanded-icon)
                                       heading
                                       (if collapsed
                                           (format "  (%d)"
                                                   (length (cdr g)))
                                         "")
                                       (if needs
                                           "  ‹needs you›"
                                         ""))
                               'face
                               'agents-hud-heading-face
                               'agents-hud-group
                               key)
                   "\n")
                  (unless collapsed
                    (dolist (e (cdr g))
                      (agents-hud--insert-entry e now))))))
            (goto-char (point-min))
            (forward-line (1- line))))))))

;;;###autoload
(defun agents-hud-refresh ()
  "Refresh the sidebar now (also used as the `g' command).
Clears the worktree→repo cache so an explicit refresh re-resolves grouping."
  (interactive)
  (clrhash agents-hud--repo-root-cache)
  (clrhash agents-hud--worktree-cache)
  (clrhash agents-hud--branch-cache)
  (agents-hud--get-buffer)
  (agents-hud--render))

(defun agents-hud--tick ()
  "Timer callback: re-render while the sidebar is visible, else stop.
Skips the render while `agents-hud--inhibit-render' is set (avy selection), so
its `erase-buffer' cannot wipe avy's label overlays out from under a keypress."
  (if (get-buffer-window agents-hud--buffer-name)
      (unless agents-hud--inhibit-render
        (agents-hud--render))
    (agents-hud--stop-timer)))

(defun agents-hud--spin ()
  "Advance the working spinner in place, without a full re-render.
Rewrites only the marked icon cells (see `agents-hud--insert-entry') via a
`display' overlay property, so the animation is smooth — no `erase-buffer'
flicker — and row positions and their entry properties are untouched.  A no-op
with no visible panel or no working rows; the refresh tick stops it with the
panel."
  (with-demoted-errors "agents-hud spin: %S"
    (let ((buf (get-buffer agents-hud--buffer-name)))
      (when (and buf
                 (get-buffer-window buf)
                 agents-hud-working-frames)
        (with-current-buffer buf
          (cl-incf agents-hud--spinner-index)
          (let ((glyph
                 (propertize (truncate-string-to-width
                              (agents-hud--working-icon) 2 0 ?\s)
                             'face 'agents-hud-working-face))
                (inhibit-read-only t)
                (pos (point-min)))
            (while (setq pos
                         (text-property-not-all
                          pos (point-max) 'agents-hud-spinner nil))
              (let ((end
                     (or (next-single-property-change
                          pos 'agents-hud-spinner)
                         (point-max))))
                (put-text-property pos end 'display glyph)
                (setq pos end)))))))))

(defun agents-hud--start-timer ()
  "Start the refresh and spinner timers if not already running."
  (unless (timerp agents-hud--timer)
    (setq agents-hud--timer
          (run-at-time
           agents-hud-refresh-interval
           agents-hud-refresh-interval
           #'agents-hud--tick)))
  (unless (timerp agents-hud--spinner-timer)
    (setq agents-hud--spinner-timer
          (run-at-time
           agents-hud-spinner-interval
           agents-hud-spinner-interval
           #'agents-hud--spin))))

(defun agents-hud--stop-timer ()
  "Stop the refresh and spinner timers."
  (when (timerp agents-hud--timer)
    (cancel-timer agents-hud--timer))
  (setq agents-hud--timer nil)
  (when (timerp agents-hud--spinner-timer)
    (cancel-timer agents-hud--spinner-timer))
  (setq agents-hud--spinner-timer nil))

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

(defun agents-hud--heading-group-at-point ()
  "Return the group key of the heading on the current line, or nil.
Read at the line start so it works from anywhere on the heading line, not only
where the `agents-hud-group' text property happens to sit."
  (get-text-property (line-beginning-position) 'agents-hud-group))

(defun agents-hud--group-at-point ()
  "Return the project-group key at point: a heading's, else the entry's group."
  (or (agents-hud--heading-group-at-point)
      (when-let ((entry (agents-hud--entry-at-point)))
        (agents-hud--group-key entry))))

(defun agents-hud-toggle-collapse ()
  "Fold or unfold the project group at point (its heading or any of its rows)."
  (interactive)
  (when-let ((key (agents-hud--group-at-point)))
    (if (gethash key agents-hud--collapsed)
        (remhash key agents-hud--collapsed)
      (puthash key t agents-hud--collapsed))
    (agents-hud--render)))

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
  "Switch to the buffer on the current line; on a group heading, fold it instead.
Keeps the panel open."
  (interactive)
  (if-let* ((entry (agents-hud--entry-at-point)))
      (agents-hud--goto-buffer (agents-hud-entry-buffer entry))
    (when (agents-hud--heading-group-at-point)
      (agents-hud-toggle-collapse))))

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

(defun agents-hud--avy-keys ()
  "Return the ordered avy key list per `agents-hud-avy-keys-style'.
A flat, in-order list so `avy-process' labels rows a, b, c … (or 1, 2, 3 …)
from the top down instead of avy's scattered home-row default."
  (pcase agents-hud-avy-keys-style
    ('numbers (append (number-sequence ?1 ?9) (list ?0)))
    (_ (number-sequence ?a ?z))))

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
      ;; Bind avy-action to our jumper (avy-process reads it).  Override
      ;; avy-keys with a flat in-order list so rows label a, b, c … (or 1, 2,
      ;; 3 …) top-down rather than avy's scattered home-row default, and keep
      ;; avy off the de-bruijn style, which would reorder the labels.  No
      ;; `avy-with' macro is used, so there is no compile-time dependency on avy.
      (let
          ((avy-action #'agents-hud--avy-action)
           (avy-keys (agents-hud--avy-keys))
           (avy-style
            (if (eq avy-style 'de-bruijn)
                'pre
              avy-style))
           ;; Freeze the refresh tick while avy blocks on a keypress; its
           ;; `erase-buffer' would otherwise delete the label overlays after
           ;; one interval, leaving invisible-but-still-live targets.
           (agents-hud--inhibit-render t))
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
