;;; claude-session.el --- The live Claude/ghostel session, as one concept -*- lexical-binding: t; -*-

;; Author: inkpotmonkey
;; Keywords: processes, terminals, ai, convenience
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; The single owner of "a live Claude/ghostel session and what it is doing".
;; A session is a live `*claude:…*' claude-code buffer or a plain `*ghostel:…*'
;; terminal (both are `ghostel-mode' buffers, claude-code driving the ghostel
;; backend).  Before this module, three consumers each re-derived the same three
;; things three incompatible ways: buffer discovery (`*claude:' prefix), the
;; `*claude:DIR:name*' name parse, and a status verdict.  This module owns all
;; three so `agents-hud' (sidebar), `project-agent' (its run/home view) and
;; `proc-notify' (its attention list) become readers over one status source.
;;
;; PUBLIC INTERFACE
;;
;;   `claude-session-list'   → a `claude-session' struct per live session.
;;   `claude-session-at'     buffer → its `claude-session' snapshot.
;;   `claude-session-status' buffer → just the state symbol.
;;   `claude-session-setup'  install the ghostel signal-collection hooks
;;                           (idempotent; degrades quietly without ghostel).
;;   plus the discovery predicates (`claude-session-claude-buffer-p',
;;   `claude-session-buffers', `claude-session-buffer-dir') that were the
;;   copy-pasted `*claude:' seam, now named in one place.
;;
;; STATUS MODEL (per session), four states, priority dead → waiting → working →
;; ready:
;;
;;   working — the terminal is churning: ghostel's OSC-133
;;             `ghostel--command-running' flag is set, or a redraw fired within
;;             `claude-session-idle-seconds'.  A redraw caused purely by you (a
;;             focus repaint, a keystroke echo) is discounted — see
;;             `claude-session-interaction-grace'.
;;   waiting — Claude is BLOCKED on a selection prompt and needs a choice from
;;             you: read from the live screen (`claude-session--selection-prompt-p'),
;;             NOT the end-of-turn bell, which fires every turn.
;;   ready   — a live process, not working and not at a prompt: standing by.
;;   dead    — no live process.
;;
;; The signal collection (redraw/focus/keystroke stamps, exit code) is inherently
;; coupled to ghostel; it is the ghostel adapter and lives here so the coupling
;; is owned in one module.  Everything the consumers render is derived by pure
;; functions (`claude-session--compute-state', the interaction guards, the
;; screen scan) that the ERT suite exercises.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;; Soft dependency on ghostel — never `require'd, so this package (and its ERT
;; suite) loads with only built-ins present.  Every use is `boundp'/`fboundp'
;; guarded.
(defvar ghostel--command-running)
(defvar ghostel--last-directory)
(defvar ghostel-inhibit-redraw-functions)
(defvar ghostel-exit-functions)
(declare-function ghostel--focus-change "ghostel" (&rest args))
(declare-function ghostel--on-user-input "ghostel" (&rest args))

;;; ── Customization ────────────────────────────────────────────────────────────

(defgroup claude-session nil
  "The live Claude/ghostel session as one concept."
  :group 'convenience
  :prefix "claude-session-")

(defcustom claude-session-idle-seconds 3.0
  "Seconds of quiet after which a working session stops counting as busy.
A redraw within this window counts the session as working; once redraws stop for
this long (and no shell command is running) it drops to ready."
  :type 'number)

(defcustom claude-session-interaction-grace 0.4
  "Seconds after a user interaction in which a redraw is not counted as work.
A terminal redraw can be caused by you rather than by Claude: switching into or
out of a buffer makes ghostel send a focus event (DEC mode 1004) that a
focus-reporting TUI repaints in response, and typing echoes each keystroke back.
Both are ordinary redraws indistinguishable from real output.  A redraw on an
otherwise-quiet buffer within this window of an interaction — a focus change
\(on EITHER side, as its repaint can fire just before or just after the focus
hook) or a keystroke — is ignored, so merely looking at or typing into a parked
session no longer flips it to working.  A session that is already active keeps
stamping normally, so genuine work is never suppressed.  Set to 0 to disable."
  :type 'number)

(defcustom claude-session-selection-prompt-regexp
  "Enter to select\\|Tab/Arrow keys to navigate\\|❯ *[0-9]+\\."
  "Regexp marking a Claude Code selection prompt on a terminal's live screen.
When it matches the bottom of a session (the last
`claude-session-selection-scan-lines' lines) the session is waiting — Claude is
blocked on a choice you must make.  The default matches the picker's `Enter to
select …' / `Tab/Arrow keys to navigate' footer and its `❯ N.' selected-option
caret (the idle input box shows `❯' followed by placeholder text, never a
number, so it does not match).  Retune if the CLI's prompt UI changes."
  :type 'regexp)

(defcustom claude-session-selection-scan-lines 20
  "How many trailing lines of a terminal to scan for a selection prompt.
Kept small so only the live screen is searched: a prompt you already answered,
scrolled up into scrollback, does not linger as a false waiting."
  :type 'integer)

(defcustom claude-session-shell-regexp
  "\\([0-9]+\\) shells?\\(?: still running\\| *·\\)"
  "Regexp matching Claude Code's running background-shell count on the live screen.
Group 1 is the count.  Matches the input footer (`· N shell ·') and the
worked-status line (`N shell(s) still running'), but deliberately NOT the
past-tense `Ran N shell command' in scrollback.  Retune if the CLI's UI changes."
  :type 'regexp)

(defcustom claude-session-shell-scan-lines 20
  "How many trailing lines of a terminal to scan for the background-shell count.
Kept small so only the live screen (the footer + worked line) is searched, not a
stale figure scrolled up into history."
  :type 'integer)

;;; ── The session ──────────────────────────────────────────────────────────────

(cl-defstruct
 (claude-session (:constructor claude-session--create))
 "A snapshot of one live Claude/ghostel session at a point in time."
 buffer ; the live terminal buffer
 type ; `claude or `shell
 dir ; live working directory (OSC-7 cwd)
 name ; instance/session name, or nil
 state ; `working / `waiting / `ready / `dead
 since ; float-time the current state began
 exit ; exit code once dead, else nil
 shells) ; count of running background shells (Claude sessions), else 0

;;; ── Discovery & name parsing (the former `*claude:' seam) ────────────────────

(defun claude-session-claude-buffer-p (buffer)
  "Non-nil when BUFFER is a claude-code session buffer."
  (string-prefix-p "*claude:" (buffer-name buffer)))

(defun claude-session--ghostel-mode-p (buffer)
  "Non-nil when BUFFER is a ghostel-mode buffer (claude or plain shell)."
  (provided-mode-derived-p (buffer-local-value 'major-mode buffer)
                           'ghostel-mode))

(defun claude-session-buffers ()
  "Return live Claude/ghostel session buffers."
  (seq-filter
   (lambda (b)
     (and (buffer-live-p b)
          (or (claude-session--ghostel-mode-p b)
              (claude-session-claude-buffer-p b))))
   (buffer-list)))

(defun claude-session--buffer-type (buffer)
  "Return \\='claude or \\='shell for BUFFER."
  (if (claude-session-claude-buffer-p buffer)
      'claude
    'shell))

(defun claude-session-buffer-dir (buffer)
  "Return BUFFER's live working directory (OSC-7 cwd if tracked)."
  (with-current-buffer buffer
    (or (and (boundp 'ghostel--last-directory)
             ghostel--last-directory)
        default-directory)))

(defun claude-session--buffer-instance (buffer type)
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

;;; ── Signal collection (ghostel adapter, buffer-local stamps) ─────────────────

(defvar-local claude-session--activity nil
  "`float-time' of this buffer's last terminal redraw, or nil.")

(defvar-local claude-session--activity-prev nil
  "The `claude-session--activity' value from before the most recent stamp.
Kept so `claude-session--note-focus-change' can roll back a display/focus
repaint that stamped a quiet buffer a few milliseconds before the focus hook.")

(defvar-local claude-session--working-since nil
  "`float-time' the current active burst began, for the working duration.")

(defvar-local claude-session--exit nil
  "Exit code recorded when this buffer's terminal process exited, or nil.")

(defvar-local claude-session--input-time nil
  "`float-time' of the last explicit user keystroke into this buffer, or nil.
Stamped by `claude-session--note-input' (advising `ghostel--on-user-input') so
`claude-session--note-activity' discounts the echo repaint typing produces and a
session you are replying to is not mistaken for one that is working.")

(defvar claude-session--focus-change-time nil
  "`float-time' of the most recent terminal focus change (any buffer), or nil.
Global, not buffer-local: `ghostel--focus-change' fires for whichever buffers
just gained or lost focus, so a single stamp covers the repaint that follows on
each of them.  Read by `claude-session--interaction-suppressed-p'.")

(defun claude-session--latest-time (&rest times)
  "Return the largest non-nil `float-time' in TIMES, or nil when all are nil."
  (let ((ts (delq nil times)))
    (and ts (apply #'max ts))))

(defun claude-session--interaction-suppressed-p
    (now interaction-time activity grace cutoff)
  "Non-nil when a redraw at NOW should be ignored as a user-interaction repaint.
INTERACTION-TIME is the last focus change or keystroke; ACTIVITY the buffer's
last redraw; GRACE the interaction window (`claude-session-interaction-grace');
CUTOFF the quiet threshold (`claude-session-idle-seconds').  Swallowed only when
an interaction landed within GRACE AND the buffer was quiet (no ACTIVITY within
CUTOFF) — i.e. this lone redraw (a focus repaint, or a keystroke echo) would
spuriously flip a parked session to working.  An already-active buffer (fresh
ACTIVITY) is never suppressed, so genuine work is never starved."
  (and interaction-time
       grace
       (> grace 0)
       (< (- now interaction-time) grace)
       (or (null activity) (>= (- now activity) cutoff))))

(defun claude-session--focus-rollback-p
    (now activity activity-prev grace cutoff)
  "Non-nil when ACTIVITY is a focus-repaint stamp to undo after a focus change.
The repaint that paints a newly-shown buffer can land a few milliseconds BEFORE
`ghostel--focus-change' updates the focus stamp, so the forward guard
\(`claude-session--interaction-suppressed-p') misses it.  On the focus change,
undo the stamp if the buffer's last redraw landed within GRACE of NOW AND it was
a quiet→active flip (ACTIVITY-PREV absent or older than CUTOFF before it).  A
genuinely working buffer re-stamps on its next redraw, so a wrong rollback
self-heals in one frame; a lone focus repaint stays rolled back."
  (and activity
       grace (> grace 0) (< (- now activity) grace)
       (or (null activity-prev)
           (>= (- activity activity-prev) cutoff))))

(defun claude-session--note-activity (buffer)
  "Stamp BUFFER's last-activity time on a redraw; never inhibit the redraw.
For `ghostel-inhibit-redraw-functions' (called with BUFFER current before each
redraw): returns nil so the redraw always proceeds.  When activity resumes
after a quiet spell it also restarts `claude-session--working-since' so the
working duration measures the current burst, not the whole session.

A redraw that is merely a user-interaction repaint on a quiet buffer is ignored,
so looking at or typing into a parked session does not flash it as working — see
`claude-session-interaction-grace'.  The focus case is bracketed: a focus change
just BEFORE the redraw suppresses it here
\(`claude-session--interaction-suppressed-p'); one just AFTER rolls it back
\(`claude-session--note-focus-change'), which is why the prior activity is kept
in `claude-session--activity-prev'.  A keystroke is stamped before its echo, so
the forward guard alone covers typing."
  (with-demoted-errors "claude-session activity: %S"
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let ((now (float-time)))
          (unless (claude-session--interaction-suppressed-p
                   now
                   (claude-session--latest-time
                    claude-session--focus-change-time
                    claude-session--input-time)
                   claude-session--activity
                   claude-session-interaction-grace
                   claude-session-idle-seconds)
            (when (or (null claude-session--activity)
                      (>= (- now claude-session--activity)
                          claude-session-idle-seconds))
              (setq claude-session--working-since now))
            (setq claude-session--activity-prev
                  claude-session--activity)
            (setq claude-session--activity now))))))
  nil)

(defun claude-session--note-focus-change (&rest _)
  "Record a terminal focus change and undo any repaint it triggered just before.
For `:after' advice on `ghostel--focus-change' (which sends the DEC mode 1004
focus events).  Stamps `claude-session--focus-change-time', so a repaint landing
just AFTER is discounted by `claude-session--note-activity'.  Then rolls back
any quiet buffer whose last redraw landed just BEFORE this hook: the repaint
that paints a newly-shown buffer fires a few ms ahead of the focus hook, which
the forward guard cannot catch (`claude-session--focus-rollback-p')."
  (with-demoted-errors "claude-session focus: %S"
    (let ((now (float-time)))
      (setq claude-session--focus-change-time now)
      (dolist (b (claude-session-buffers))
        (with-current-buffer b
          (when (claude-session--focus-rollback-p
                 now
                 claude-session--activity
                 claude-session--activity-prev
                 claude-session-interaction-grace
                 claude-session-idle-seconds)
            (setq claude-session--activity
                  claude-session--activity-prev)))))))

(defun claude-session--note-input (&rest _)
  "Stamp `claude-session--input-time' on a user keystroke into a terminal.
For `:before' advice on `ghostel--on-user-input', which runs in the terminal
buffer just before the key reaches the PTY — hence before the echo repaint, so
`claude-session--note-activity' discounts that repaint and typing a reply does
not read as Claude working."
  (with-demoted-errors "claude-session input: %S"
    (setq claude-session--input-time (float-time))))

(defun claude-session--note-exit (buffer event)
  "Record BUFFER's process exit code parsed from EVENT.
For `ghostel-exit-functions', which fires before the buffer may be killed."
  (with-demoted-errors "claude-session exit: %S"
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq claude-session--exit
              (cond
               ((string-match "code \\([0-9]+\\)" event)
                (string-to-number (match-string 1 event)))
               ((string-match-p "finished" event)
                0)
               (t
                nil)))))))

;;; ── State computation (pure) ─────────────────────────────────────────────────

(defun claude-session--selection-prompt-p (buffer)
  "Non-nil when BUFFER's live screen shows a Claude Code selection prompt.
The picker Claude Code puts up when it is blocked on your choice — a permission
dialog, plan approval, the shift-tab mode menu — renders numbered options with a
`❯' caret and an `Enter to select …' footer.  That, not the end-of-turn bell, is
what waiting means: the bell fires every turn and would flag every finished
session.  Only the last `claude-session-selection-scan-lines' lines (the live
screen) are searched, so a prompt already answered and scrolled up into history
does not count."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (save-excursion
        (goto-char (point-max))
        (forward-line (- claude-session-selection-scan-lines))
        (and (re-search-forward claude-session-selection-prompt-regexp
                                nil
                                t)
             t)))))

(cl-defun
 claude-session--compute-state
 (&key
  live
  cmd-running
  waiting
  activity
  (now (float-time))
  (cutoff claude-session-idle-seconds))
 "Resolve a session's status symbol from its signals.
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

(defun claude-session--shell-count (text)
  "Return the number of running background shells reported in TEXT, or 0.
Scans TEXT for `claude-session-shell-regexp' and returns the count from the LAST
match, so the current footer wins over any earlier figure.  Orthogonal to the
state: a session can be `ready' (idle) while a background shell keeps running."
  (let ((n 0)
        (start 0))
    (while (string-match claude-session-shell-regexp text start)
      (setq
       n (string-to-number (match-string 1 text))
       start (match-end 0)))
    n))

(defun claude-session--shells (buffer)
  "Return the number of running background shells on BUFFER's live screen.
Reads the last `claude-session-shell-scan-lines' lines and applies
`claude-session--shell-count'.  0 for a plain shell or a session with none."
  (if (buffer-live-p buffer)
      (with-current-buffer buffer
        (save-excursion
          (goto-char (point-max))
          (forward-line (- claude-session-shell-scan-lines))
          (claude-session--shell-count
           (buffer-substring-no-properties (point) (point-max)))))
    0))

;;; ── Snapshots (the public interface) ─────────────────────────────────────────

(defun claude-session-at (buffer &optional now)
  "Return a `claude-session' snapshot for BUFFER at time NOW.
Reads the buffer-local activity stamps, ghostel's command-running flag, and the
live screen; resolves the state through `claude-session--compute-state'."
  (let* ((now (or now (float-time)))
         (type (claude-session--buffer-type buffer))
         (proc (get-buffer-process buffer))
         (live (and proc (process-live-p proc)))
         (activity
          (buffer-local-value 'claude-session--activity buffer))
         (working-since
          (buffer-local-value 'claude-session--working-since buffer))
         (cmd-running
          (and (boundp 'ghostel--command-running)
               (buffer-local-value 'ghostel--command-running buffer)))
         (waiting (claude-session--selection-prompt-p buffer))
         (state
          (claude-session--compute-state
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
            (_ nil))))
    (claude-session--create
     :buffer buffer
     :type type
     :dir (claude-session-buffer-dir buffer)
     :name
     (claude-session--buffer-instance buffer type)
     :state state
     :since since
     :exit
     (buffer-local-value 'claude-session--exit buffer)
     :shells (claude-session--shells buffer))))

(defun claude-session-list (&optional now)
  "Return a `claude-session' snapshot for every live Claude/ghostel session."
  (let ((now (or now (float-time))))
    (mapcar
     (lambda (b) (claude-session-at b now))
     (claude-session-buffers))))

(defun claude-session-status (buffer &optional now)
  "Return just the state symbol for BUFFER (see `claude-session-at').
The convenience seam for readers that want the verdict, not the whole snapshot:
`working', `waiting', `ready' or `dead'."
  (claude-session-state (claude-session-at buffer now)))

;;; ── Setup ────────────────────────────────────────────────────────────────────

(defvar claude-session--setup-done nil
  "Non-nil once `claude-session-setup' has installed its hooks/advice.")

;;;###autoload
(defun claude-session-setup ()
  "Install the ghostel signal-collection hooks and advice (idempotent).
Wires redraw-activity stamping and exit recording on ghostel, and the
focus/keystroke interaction guards.  Safe to call when ghostel is not yet
loaded; the pieces attach as it loads.  Waiting is read from the live screen at
query time (`claude-session--selection-prompt-p'), so it needs no hook here."
  (interactive)
  (unless claude-session--setup-done
    (with-eval-after-load 'ghostel
      (add-hook
       'ghostel-inhibit-redraw-functions
       #'claude-session--note-activity)
      (add-hook 'ghostel-exit-functions #'claude-session--note-exit)
      ;; Discount redraws you cause rather than Claude: the repaint a
      ;; focus-reporting TUI makes on focus in/out, and the echo of your own
      ;; keystrokes, so looking at or typing into a parked session does not
      ;; flash it as working (see `claude-session-interaction-grace').
      (when (fboundp 'ghostel--focus-change)
        (advice-add
         'ghostel--focus-change
         :after #'claude-session--note-focus-change))
      (when (fboundp 'ghostel--on-user-input)
        (advice-add
         'ghostel--on-user-input
         :before #'claude-session--note-input)))
    (setq claude-session--setup-done t)))

(provide 'claude-session)
;;; claude-session.el ends here
