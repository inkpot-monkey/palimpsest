;;; proc-notify.el --- Desktop notifications when a process buffer needs you -*- lexical-binding: t; -*-

;; Author: inkpotmonkey
;; Keywords: processes, convenience
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Bridge between Emacs process buffers and the desktop notification daemon
;; (freedesktop `org.freedesktop.Notifications', e.g. KDE Plasma), for the case
;; where Emacs runs as a backgrounded daemon and a process buffer you are not
;; looking at is blocking on input.  The notification is only the *alert*; the
;; place you type is the real Emacs buffer (or its minibuffer password prompt),
;; so this stays "still Emacs buffers".
;;
;; Three triggers, installed together by `proc-notify-setup':
;;
;;   * Password prompts.  Comint already detects these (see
;;     `comint-watch-for-password-prompt') and reads the password in the
;;     minibuffer via `comint-send-invisible'.  We advise that chokepoint to
;;     fire a notification *just before* it blocks, so an `async-shell-command'
;;     that hits `[sudo] password for …' pops a notification; activating it
;;     raises Emacs so you can type the password into the waiting minibuffer.
;;
;;   * Process needs input.  A heuristic for the general case: a running comint
;;     process whose output has fallen silent for `proc-notify-idle-seconds',
;;     whose last line has no trailing newline and looks like a prompt
;;     (`proc-notify-prompt-regexp' — ends in `?'/`:', or a `[y/n]' / `(yes/no)'
;;     style query), gets a notification.  Activating it jumps to the buffer
;;     with point at the prompt so you can type the answer.
;;
;;   * Command finished.  `async-shell-command' installs `shell-command-sentinel'
;;     on its process; we advise it `:after' so a backgrounded command pops a
;;     toast as it exits — normal urgency on a clean exit, critical on a non-zero
;;     exit or signal (see `proc-notify-shell-command-*-severity').  Activating
;;     it raises the output buffer.  Toggle with `proc-notify-shell-command-exit'.
;;
;; ghostel / claude-code terminals.  ghostel is a libghostty PTY terminal, not
;; comint, so the two triggers above never reach it.  Three paths cover it:
;;
;;   * claude-code.el has its OWN notification path: the Claude CLI rings the
;;     terminal BELL when it finishes and is waiting for you, claude-code catches
;;     that bell (per backend) and calls `claude-code-notification-function' with
;;     a title/body — its default merely `message's and pulses the modeline.
;;     `proc-notify-setup' points that knob at proc-notify, so "Claude is waiting
;;     for input" becomes a clickable, raise-the-buffer toast.  This is THE event
;;     to respond to for claude-code — not ghostel's OSC handler.
;;
;;   * Plain ghostel terminals (a shell, a REPL) that emit OSC 9/777 desktop
;;     notifications go through `alert' via ghostel's own `ghostel-default-notify',
;;     which `proc-notify-setup' routes to our style with a `ghostel-mode' rule.
;;
;;   * In-terminal password prompts go through `ghostel-password-prompt-functions'.
;;
;; Delivery & routing.  Every notification is emitted through `alert' (Wiegley's
;; alert.el) and delivered by a custom `proc-notify' alert style — alert is only
;; the router (its `alert-add-rule' engine can re-route or drop by category,
;; severity, mode, or focus state), while the style owns the clickable,
;; raise-the-buffer behaviour.  `proc-notify-setup' routes our own
;; (category `proc-notify') and ghostel (`ghostel-mode') alerts to that style and
;; leaves every other package's alerts on alert's default.  Notifications can be
;; chatty (claude-code pings once per turn); narrow them with
;; `proc-notify-ignore-regexps' (simple) or `alert-add-rule' (richer), or tune
;; their urgency with `proc-notify-claude-code-severity'.
;;
;; Notifications are suppressed while you are already watching the buffer (Emacs
;; frame focused and that buffer selected), coalesced per buffer via
;; `:replaces-id', and silently skipped when no D-Bus session bus is reachable
;; (tty / headless).
;;
;; Wayland note: under Wayland a process may not raise itself — KWin's
;; focus-stealing prevention silently drops Emacs's own `raise-frame' /
;; `select-frame-set-input-focus' (verified on KWin 6.6.5).  So after the
;; in-Emacs focus, `proc-notify--raise' asks the *compositor* to foreground the
;; window via `proc-notify-raise-method' (kdotool or KWin scripting on KDE) —
;; privileged activation that FSP allows.  On X11 / WMs that honour app raises,
;; leave the method at `pgtk'.  Needs a graphical Emacs frame to bring forward:
;; activating from a purely headless daemon has no window to raise.

;;; Code:

(require 'comint)
(require 'notifications)
(require 'alert)
(require 'subr-x)
(require 'seq)
(require 'rx)

;; ghostel and claude-code are heavy optional packages (native module / external
;; CLI); don't `require' them.  These declarations silence byte-compile warnings
;; for the terminal bridges, which only run under `with-eval-after-load'.
(defvar ghostel-password-prompt-functions)
(defvar claude-code-notification-function)
(declare-function claude-code--pulse-modeline "claude-code")

;; consult is a soft dependency of the pull-side `proc-notify-consult' command,
;; `require'd lazily when it runs.  Declared here only to quiet the compiler.
(declare-function consult--read "consult")
(declare-function consult--buffer-preview "consult")

(defgroup proc-notify nil
  "Desktop notifications when an Emacs process buffer needs input."
  :group 'processes
  :prefix "proc-notify-")

(defcustom proc-notify-idle-seconds 4
  "Seconds a running process must be silent before a needs-input notification."
  :type 'number)

(defcustom proc-notify-app-name "Emacs"
  "Application name shown on the desktop notification."
  :type 'string)

(defcustom proc-notify-app-icon nil
  "Icon used to brand notifications, or nil to auto-detect the Emacs icon.
Some notification daemons (KDE Plasma's, notably) resolve only absolute file
paths here, not freedesktop theme names — so the default behaviour searches the
XDG data dirs for the installed Emacs icon and sends that path.  Set to an
absolute path to override, or to a theme name if your daemon resolves those."
  :type '(choice (const :tag "Auto-detect Emacs icon" nil) string))

(defcustom proc-notify-timeout-seconds 10
  "Seconds after which a notification auto-dismisses, or nil for daemon default.
Sent to the server as the notification's expire timeout.  Some servers ignore
it for `critical' urgency — KDE keeps password prompts up until you act, which
is usually what you want, while normal-urgency pings (needs-input, claude-code)
still clear.  Set to 0 to ask the server never to expire the notification."
  :type '(choice (const :tag "Daemon default" nil) number))

(defcustom proc-notify-prompt-regexp
  (rx
   (or (seq (any "?:") (* " ") eos)
       (seq "[" (* (any "yYnN/")) "]" (* " ") eos)
       (seq "(" (or "yes" "Yes") "/" (or "no" "No") ")" (* " ") eos)))
  "Regexp matched against the last (unterminated) output line.
When it matches and the line has no trailing newline, a running process is
treated as waiting for input.  Deliberately excludes the usual shell prompt
endings (`$', `%', `#', `>') to avoid firing on idle interactive shells."
  :type 'regexp)

(defcustom proc-notify-ignore-regexps nil
  "Regexps that suppress a notification before it pops.
Each is matched case-insensitively against \"TITLE: BODY\"; a match drops the
desktop popup.  The simple knob for narrowing noise (e.g. Claude Code's
per-turn pings) — start empty and append patterns as you learn them.  For
richer routing (by severity, category, or focus state) add `alert' rules with
`alert-add-rule' instead; both are honoured."
  :type '(repeat regexp))

(defcustom proc-notify-filter-function nil
  "Optional extra predicate gating notifications.
Called with TITLE, BODY, and BUFFER in the originating buffer; return non-nil
to allow.  nil (the default) allows everything not dropped by
`proc-notify-ignore-regexps'."
  :type '(choice (const :tag "Allow all" nil) function))

(defcustom proc-notify-raise-method 'auto
  "How to bring the Emacs window to the foreground on notification activation.
Under Wayland a process may not raise itself (the compositor blocks
focus-stealing), so Emacs's own `select-frame-set-input-focus' silently fails
and the window must be activated by the compositor:

  `auto'    Detect: `kdotool' if on PATH, else KWin scripting (KDE/Wayland via
            `qdbus'), else just the in-Emacs raise.
  `pgtk'    In-Emacs `select-frame-set-input-focus' only (X11/some WMs).
  `kdotool' Shell out to kdotool (KWin/Wayland).
  `kwin'    KWin scripting via qdbus (KDE/Wayland), needs no extra package.
  function  Called with the target FRAME; do your own activation.

The in-Emacs raise is always attempted first; this is the extra OS-level step."
  :type
  '(choice
    (const auto) (const pgtk) (const kdotool) (const kwin) function))

(defcustom proc-notify-claude-code-severity 'normal
  "`alert' severity for claude-code \"waiting for your response\" pings.
claude-code notifies once per turn when Claude finishes and wants you.  `normal'
(the default) maps to a normal-urgency toast that auto-expires; raise to `high'
to make them critical — sticky on KDE — if you keep missing them.  Password
prompts stay `high' regardless of this."
  :type
  '(choice
    (const trivial)
    (const low)
    (const normal)
    (const moderate)
    (const high)
    (const urgent)))

(defcustom proc-notify-shell-command-exit t
  "Whether to notify when an `async-shell-command' finishes.
When non-nil, a backgrounded async shell command (including those launched by
chelys-galactica) pops a toast as it exits: a clean exit at
`proc-notify-shell-command-success-severity', a non-zero exit or signal at
`proc-notify-shell-command-failure-severity'.  Suppressed, like every
proc-notify popup, while you are already watching the buffer."
  :type 'boolean)

(defcustom proc-notify-shell-command-success-severity 'normal
  "`alert' severity for a clean (exit 0) `async-shell-command' completion.
`normal' (the default) maps to a normal-urgency toast that auto-expires."
  :type
  '(choice
    (const trivial)
    (const low)
    (const normal)
    (const moderate)
    (const high)
    (const urgent)))

(defcustom proc-notify-shell-command-failure-severity 'high
  "`alert' severity for a failed (non-zero exit or signal) `async-shell-command'.
`high' (the default) maps to a critical toast — sticky on KDE — so a build or
deploy that died while backgrounded does not slip past you.  Lower it if failed
commands are noisy and you would rather they auto-expire too."
  :type
  '(choice
    (const trivial)
    (const low)
    (const normal)
    (const moderate)
    (const high)
    (const urgent)))

(defvar-local proc-notify--id nil
  "Notification id last raised for this buffer, for `:replaces-id' coalescing.")

(defvar-local proc-notify--idle-timer nil
  "Per-buffer idle timer arming the needs-input check.")

(defvar proc-notify--pending nil
  "Buffers that have raised a not-yet-acknowledged notification.
The pull-side companion `proc-notify-consult' reads this, unioned with any
comint buffer currently parked at a prompt.")

(defun proc-notify--graphical-frame ()
  "Return a graphical frame to raise, creating one if none is visible."
  (or (seq-find
       (lambda (f)
         (and (frame-live-p f)
              (display-graphic-p f)
              (eq (frame-visible-p f) t)))
       (frame-list))
      (seq-find
       (lambda (f)
         (and (frame-live-p f) (display-graphic-p f)))
       (frame-list))
      (ignore-errors
        (make-frame))))

(defun proc-notify--emacs-focused-p ()
  "Non-nil when some graphical Emacs frame currently has input focus."
  (seq-some (lambda (f) (eq t (frame-focus-state f))) (frame-list)))

(defun proc-notify--watching-p (buffer)
  "Non-nil when the user is already looking at BUFFER (focused + selected)."
  (and (proc-notify--emacs-focused-p)
       (eq buffer (window-buffer (selected-window)))))

(defun proc-notify--summary (buffer)
  "A short human label for BUFFER: its command if known, else its name."
  (with-current-buffer buffer
    (or (and (boundp 'async-shell-history--command)
             async-shell-history--command)
        (car-safe (bound-and-true-p compilation-arguments))
        (buffer-name buffer))))

(defun proc-notify--clean (s)
  "Tidy string S for a notification body: trim, collapse whitespace, cap length.
Returns nil for a nil or blank S."
  (when (stringp s)
    (let ((trimmed
           (string-trim
            (replace-regexp-in-string "[ \t\n\r]+" " " s))))
      (unless (string-empty-p trimmed)
        (if (> (length trimmed) 200)
            (concat (substring trimmed 0 199) "…")
          trimmed)))))

(defun proc-notify--claude-label (buffer)
  "A short session label for a claude-code BUFFER, e.g. \"Claude · nixos\".
Uses the buffer's project/working-directory name when available."
  (with-current-buffer buffer
    (let ((dir
           (and (stringp default-directory)
                (file-name-nondirectory
                 (directory-file-name default-directory)))))
      (if (and dir (not (string-empty-p dir)))
          (format "Claude · %s" dir)
        "Claude"))))

(defun proc-notify--remember (buffer)
  "Record BUFFER as awaiting attention."
  (when (and (buffer-live-p buffer)
             (not (memq buffer proc-notify--pending)))
    (push buffer proc-notify--pending)))

(defun proc-notify--forget (buffer)
  "Drop BUFFER from the awaiting-attention set (it has been dealt with)."
  (setq proc-notify--pending (delq buffer proc-notify--pending)))

(defun proc-notify--acknowledge (buffer)
  "Mark BUFFER dealt-with: drop it from pending and close its lingering toast.
Closing the desktop notification by its stored id means acknowledging a buffer
by any route — clicking the toast or simply visiting the buffer — also clears
it from the notification centre, instead of leaving a stale popup behind."
  (when (buffer-live-p buffer)
    (when-let ((id (buffer-local-value 'proc-notify--id buffer)))
      (condition-case nil
          (notifications-close-notification id)
        (error
         nil))
      (with-current-buffer buffer
        (setq proc-notify--id nil))))
  (proc-notify--forget buffer))

(defun proc-notify--note-selection (&rest _)
  "Acknowledge the selected window's buffer: clear its flag and close its toast.
Installed on `window-selection-change-functions' so visiting a flagged buffer by
any means drops it from `proc-notify--pending' and dismisses any lingering
desktop notification."
  (proc-notify--acknowledge (window-buffer (selected-window))))

;; --- OS-level window activation (the Wayland-needs-the-compositor step) ------

(defvar proc-notify--kwin-script-file nil
  "Cached path of the generated KWin activation script.")

(defun proc-notify--kwin-script ()
  "Return a KWin script file that activates the first normal Emacs window."
  (or
   (and proc-notify--kwin-script-file
        (file-exists-p proc-notify--kwin-script-file)
        proc-notify--kwin-script-file)
   (let ((f (make-temp-file "proc-notify-activate" nil ".js")))
     (with-temp-file f
       (insert
        "const ws = (typeof workspace.windowList === 'function')"
        " ? workspace.windowList() : workspace.clientList();\n"
        "for (let i = 0; i < ws.length; i++) {\n"
        "  const w = ws[i];\n"
        "  if (w && w.normalWindow &&"
        " String(w.resourceClass).toLowerCase().indexOf('emacs') !== -1) {\n"
        "    w.minimized = false; workspace.activeWindow = w; break;\n"
        "  }\n"
        "}\n"))
     (setq proc-notify--kwin-script-file f))))

(defun proc-notify--activate-kdotool ()
  "Activate the Emacs window via kdotool.  Return non-nil on success."
  (when-let ((kd (executable-find "kdotool")))
    (eq
     0
     (call-process kd
                   nil
                   nil
                   nil
                   "search"
                   "--class"
                   "emacs"
                   "windowactivate"))))

(defun proc-notify--activate-kwin ()
  "Activate the Emacs window via KWin scripting (qdbus).  Non-nil on success.
Privileged scripting activation bypasses KWin focus-stealing prevention, which
blocks an app's own `raise-frame' under Wayland."
  (when-let ((qdbus
              (or (executable-find "qdbus6")
                  (executable-find "qdbus"))))
    (let ((script (proc-notify--kwin-script))
          (plugin "procnotifyactivate")
          (args '("org.kde.KWin" "/Scripting")))
      ;; Unload any prior run, (re)load the script, then start it.  We leave it
      ;; loaded; the next activation unloads it first, avoiding a start/unload
      ;; race.
      (apply #'call-process
             qdbus nil nil nil
             (append
              args
              '("org.kde.kwin.Scripting.unloadScript"
                "procnotifyactivate")))
      (and (eq
            0
            (apply #'call-process
                   qdbus nil nil nil
                   (append
                    args
                    (list
                     "org.kde.kwin.Scripting.loadScript"
                     script
                     plugin))))
           (eq
            0
            (apply #'call-process
                   qdbus nil nil nil
                   (append
                    args '("org.kde.kwin.Scripting.start"))))))))

(defun proc-notify--os-activate (frame)
  "Ask the OS/compositor to bring Emacs forward, per `proc-notify-raise-method'.
FRAME is the in-Emacs frame already focused; passed to a custom function."
  (pcase proc-notify-raise-method
    ('pgtk nil)
    ('kdotool (proc-notify--activate-kdotool))
    ('kwin (proc-notify--activate-kwin))
    ('auto
     (or (proc-notify--activate-kdotool)
         (proc-notify--activate-kwin)))
    ((and (pred functionp) fn) (funcall fn frame))))

(defun proc-notify--raise (buffer)
  "Foreground Emacs and pop to BUFFER with point at its process prompt.
Under Wayland a process can't raise itself, so after the in-Emacs focus we ask
the compositor to bring the window forward via `proc-notify-raise-method'."
  (proc-notify--acknowledge buffer)
  (let ((frame (proc-notify--graphical-frame)))
    (when (frame-live-p frame)
      (select-frame frame)
      (when (buffer-live-p buffer)
        (pop-to-buffer buffer)
        (when (get-buffer-process buffer)
          (goto-char (point-max))))
      (select-frame-set-input-focus frame)
      (raise-frame frame)
      (proc-notify--os-activate frame))))

(defvar proc-notify--app-icon-cache 'unset
  "Memoised result of `proc-notify--app-icon' (`unset' before first lookup).")

(defun proc-notify--app-icon ()
  "Absolute path of the icon to brand notifications with, or nil.
Honours `proc-notify-app-icon' when set; otherwise finds the installed Emacs
icon under the XDG data dirs (a real path, since some daemons resolve only
paths, not theme names) and memoises it."
  (or proc-notify-app-icon
      (if (not (eq proc-notify--app-icon-cache 'unset))
          proc-notify--app-icon-cache
        (setq proc-notify--app-icon-cache
              (seq-some
               (lambda (dir)
                 (let ((f
                        (expand-file-name
                         "icons/hicolor/128x128/apps/emacs.png"
                         dir)))
                   (and (file-exists-p f) f)))
               (split-string (or (getenv "XDG_DATA_DIRS") "")
                             ":"
                             t))))))

(defun proc-notify--timeout-ms ()
  "Server expire-timeout in milliseconds from `proc-notify-timeout-seconds'.
Returns nil when no timeout is configured (leave the server's default)."
  (when proc-notify-timeout-seconds
    (round (* 1000 proc-notify-timeout-seconds))))

(defun proc-notify--notify (buffer title body &optional urgency)
  "Raise (or replace) a desktop notification for BUFFER.
TITLE and BODY are the notification text; URGENCY is a `notifications-notify'
urgency symbol.  The Emacs icon (`proc-notify--app-icon') is attached as both
app-icon and image so it brands the popup, and `proc-notify-timeout-seconds'
sets when it auto-dismisses.  Activating it runs `proc-notify--raise' on BUFFER.
A missing D-Bus session bus is swallowed so headless/tty sessions stay quiet."
  (condition-case nil
      (let ((icon (proc-notify--app-icon))
            (id nil))
        (setq
         id
         (apply
          #'notifications-notify
          :app-name proc-notify-app-name
          :title title
          :body (format "%s" body)
          :replaces-id (buffer-local-value 'proc-notify--id buffer)
          :urgency (or urgency 'normal)
          :actions '("default" "Open")
          :on-action
          (lambda (&rest _) (proc-notify--raise buffer))
          (append
           (when icon
             (list :app-icon icon :image-path icon))
           (let ((ms (proc-notify--timeout-ms)))
             (when ms
               (list :timeout ms))))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (setq proc-notify--id id))
          (proc-notify--remember buffer)))
    (dbus-error
     nil)
    (error
     nil)))

;;; --- alert delivery layer ---------------------------------------------------

;; `alert' is the router: every notification is emitted with `proc-notify--emit',
;; which goes through alert so its rule engine (`alert-add-rule') can re-route or
;; drop by category / severity / mode / focus state.  Delivery itself is OUR
;; `proc-notify' style, so the clickable, raise-the-buffer behaviour is fully
;; ours — alert decides whether and how loudly, we decide what the popup does.

(defun proc-notify--severity->urgency (severity)
  "Map an `alert' SEVERITY symbol to a `notifications-notify' urgency."
  (pcase severity
    ((or 'urgent 'high) 'critical)
    ((or 'low 'trivial) 'low)
    (_ 'normal)))

(defun proc-notify--allow-p (title body buffer)
  "Non-nil when a notification of TITLE/BODY for BUFFER should pop."
  (let ((hay (format "%s: %s" (or title "") (or body ""))))
    (and (not
          (seq-some
           (lambda (re)
             (let ((case-fold-search t))
               (string-match-p re hay)))
           proc-notify-ignore-regexps))
         (or (null proc-notify-filter-function)
             (funcall proc-notify-filter-function
                      title
                      body
                      buffer)))))

(defun proc-notify--alert-notifier (info)
  "`alert' style notifier: deliver INFO as a clickable, raise-the-buffer popup.
Suppressed while you are watching the buffer or when filtered by
`proc-notify-ignore-regexps' / `proc-notify-filter-function'."
  (let ((buffer (or (plist-get info :buffer) (current-buffer)))
        (title (plist-get info :title))
        (body (plist-get info :message)))
    (when (and (buffer-live-p buffer)
               (not (proc-notify--watching-p buffer))
               (proc-notify--allow-p title body buffer))
      (proc-notify--notify buffer
                           (if (and title
                                    (not (string-empty-p title)))
                               title
                             (buffer-name buffer))
                           body
                           (proc-notify--severity->urgency
                            (plist-get info :severity))))))

(alert-define-style
 'proc-notify
 :title "Raise the originating Emacs buffer"
 :notifier #'proc-notify--alert-notifier)

(defun proc-notify--emit (buffer title body &optional severity)
  "Emit a notification for BUFFER via `alert' (category `proc-notify').
TITLE/BODY are the text; SEVERITY an `alert' severity (default `normal')."
  (alert
   (or body "")
   :title title
   :category 'proc-notify
   :severity (or severity 'normal)
   :buffer buffer))

;;; --- Password prompts -------------------------------------------------------

(defun proc-notify--password-advice (&optional prompt &rest _)
  "Before `comint-send-invisible' blocks on a password, emit a notification.
PROMPT is the prompt comint matched (e.g. \"[sudo] password for thomas:\"); it
is shown as the body so the toast says exactly what is being asked."
  (let ((buffer (current-buffer)))
    (when (derived-mode-p 'comint-mode)
      (proc-notify--emit
       buffer
       (proc-notify--summary buffer)
       (or (proc-notify--clean prompt) "Needs your password")
       'high))))

;;; --- Process needs input ----------------------------------------------------

(defun proc-notify--idle-check (buffer)
  "Emit a needs-input notification if BUFFER's process is parked at a prompt."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((proc (get-buffer-process buffer))
            (line (proc-notify--prompt-line)))
        (when (and proc (process-live-p proc) line)
          (proc-notify--emit buffer
                             (proc-notify--summary buffer)
                             (proc-notify--clean line)
                             'normal))))))

(defun proc-notify--prompt-line ()
  "Return the trailing unterminated prompt-shaped line, or nil.
The line itself is the human-meaningful question (e.g. \"Overwrite? [y/n]\")."
  (save-excursion
    (goto-char (point-max))
    (let ((line
           (buffer-substring-no-properties
            (line-beginning-position) (point-max))))
      (and
       (not (bolp)) ; unterminated last line — a process awaiting input
       (string-match-p proc-notify-prompt-regexp line) line))))

(defun proc-notify--looks-like-prompt-p ()
  "Non-nil when the buffer ends in an unterminated, prompt-shaped line."
  (and (proc-notify--prompt-line) t))

(defun proc-notify--arm-idle (&rest _)
  "Comint output-filter hook: (re)arm BUFFER's needs-input idle timer."
  (when (derived-mode-p 'comint-mode)
    (when (timerp proc-notify--idle-timer)
      (cancel-timer proc-notify--idle-timer))
    (let ((buffer (current-buffer)))
      (setq proc-notify--idle-timer
            (run-with-timer
             proc-notify-idle-seconds nil #'proc-notify--idle-check
             buffer)))))

;;; --- async-shell-command completion -----------------------------------------

;; `async-shell-command' (the chelys-galactica front-end included) installs
;; `shell-command-sentinel' on its process; it fires once on exit/signal with a
;; human-readable SIGNAL ("finished", "exited abnormally with code 1", ...).  We
;; advise it `:after' to turn that completion into a toast — success at
;; `proc-notify-shell-command-success-severity', failure (non-zero exit or a
;; signal) at `proc-notify-shell-command-failure-severity'.  Like every other
;; trigger this routes through `proc-notify--emit', so it is suppressed while you
;; are watching the buffer and tunable via the same ignore/filter knobs.

(defun proc-notify--shell-command-exit-advice (process signal)
  "Notify that an `async-shell-command' PROCESS has finished.
For `:after' advice on `shell-command-sentinel'.  SIGNAL is the state-change
description; it is shown verbatim as the body on failure so the toast says how
it died (e.g. \"exited abnormally with code 1\")."
  (when (and proc-notify-shell-command-exit
             (memq (process-status process) '(exit signal)))
    (let ((buffer (process-buffer process)))
      (when (buffer-live-p buffer)
        (let ((ok
               (and (eq (process-status process) 'exit)
                    (eq (process-exit-status process) 0))))
          (proc-notify--emit
           buffer (proc-notify--summary buffer)
           (if ok
               "Finished"
             (let ((d (string-trim (or signal ""))))
               (if (string-empty-p d)
                   "Failed"
                 (concat
                  (upcase (substring d 0 1)) (substring d 1)))))
           (if ok
               proc-notify-shell-command-success-severity
             proc-notify-shell-command-failure-severity)))))))

;;; --- ghostel terminal bridge ------------------------------------------------

;; ghostel is a libghostty PTY terminal, not comint, so none of the comint hooks
;; above reach it.  Two ghostel paths below (claude-code is handled separately,
;; further down, via its own bell-driven notification function — NOT these):
;;
;;   * OSC 9/777 desktop notifications from a plain ghostel terminal (a shell, a
;;     REPL) need no glue here: ghostel's own `ghostel-default-notify' already
;;     calls `alert', and `proc-notify-setup' adds a rule routing `ghostel-mode'
;;     alerts to the `proc-notify' style — so they become clickable,
;;     raise-the-buffer popups like everything else, filtered by the same knobs.
;;
;;   * Password prompts are NOT notifications; ghostel reads them via
;;     `ghostel-password-prompt-functions'.  We add a source there that emits a
;;     notification and then returns nil, deferring to the real `read-passwd'.

(defun proc-notify-ghostel-password-source (row)
  "Notify on a ghostel password prompt, then defer to the real reader.
For `ghostel-password-prompt-functions': always returns nil so the normal
`read-passwd' (or a later auth source) still handles entry.  ROW is the
trimmed cursor-row text at detection."
  (proc-notify--emit
   (current-buffer)
   (proc-notify--summary (current-buffer))
   (or (proc-notify--clean row) "Needs your password")
   'high)
  nil)

(defun proc-notify-ghostel-setup ()
  "Bridge ghostel password prompts into proc-notify.
OSC notifications from plain ghostel terminals are handled by the `ghostel-mode'
`alert' rule installed in `proc-notify-setup'; this only wires the
password-prompt path.  (claude-code has its own notification path — see
`proc-notify-claude-code-setup'.)"
  (add-hook
   'ghostel-password-prompt-functions
   #'proc-notify-ghostel-password-source))

;;; --- claude-code bridge -----------------------------------------------------

;; claude-code.el does NOT use ghostel's OSC handler for its notifications.  When
;; Claude finishes and is waiting on you, the CLI rings the terminal BELL;
;; claude-code catches that bell (per backend: `ring-bell-function' for ghostel /
;; eat, a `vterm--filter' advice for vterm) and calls
;; `claude-code-notification-function' with a title and body.  Its default just
;; `message's and pulses the modeline.  We repoint that knob at proc-notify so
;; the "Claude is waiting for input" event becomes a clickable, raise-the-buffer
;; desktop toast — keeping the modeline pulse for in-frame feedback.

(defun proc-notify-claude-code-notify (title message)
  "Deliver a claude-code notification (TITLE/MESSAGE) through proc-notify.
For `claude-code-notification-function': the bell handler runs in the Claude
terminal buffer, so `proc-notify--emit' on the current buffer raises the right
buffer when the toast is activated.  The title is a per-session label
\(`proc-notify--claude-label', e.g. \"Claude · nixos\") so concurrent sessions are
distinguishable; MESSAGE (claude-code's own text) is the body.  Urgency follows
`proc-notify-claude-code-severity'.  TITLE is unused.  Keeps claude-code's
modeline pulse when available."
  (ignore title)
  (proc-notify--emit (current-buffer)
                     (proc-notify--claude-label (current-buffer))
                     (proc-notify--clean message)
                     proc-notify-claude-code-severity)
  (when (fboundp 'claude-code--pulse-modeline)
    (claude-code--pulse-modeline)))

(defun proc-notify-claude-code-setup ()
  "Make claude-code deliver its notifications through proc-notify."
  (setq claude-code-notification-function
        #'proc-notify-claude-code-notify))

;;; --- consult companion (pull side) ------------------------------------------

;; The notifications above are push: they come to you per blocked buffer.  This
;; is the pull complement — list, on demand, everything currently wanting
;; attention so you can triage several at once from inside Emacs.

(defun proc-notify--awaiting-buffers ()
  "Live buffers wanting attention: pending pings ∪ comint buffers at a prompt.
Buffers you are already watching are excluded; dead buffers are pruned."
  (setq proc-notify--pending
        (seq-filter #'buffer-live-p proc-notify--pending))
  (let ((parked
         (seq-filter
          (lambda (buf)
            (with-current-buffer buf
              (and (derived-mode-p 'comint-mode)
                   (let ((proc (get-buffer-process buf)))
                     (and proc (process-live-p proc)))
                   (proc-notify--looks-like-prompt-p))))
          (buffer-list))))
    (seq-remove
     #'proc-notify--watching-p
     (seq-uniq (append proc-notify--pending parked)))))

;;;###autoload
(defun proc-notify-consult ()
  "Pick a buffer that is waiting for input and jump to it.
Candidates are `proc-notify--awaiting-buffers': buffers that pinged plus any
comint process currently parked at a prompt."
  (interactive)
  (require 'consult)
  (let ((buffers (proc-notify--awaiting-buffers)))
    (unless buffers
      (user-error "No buffers are waiting for input"))
    (let ((choice
           (consult--read
            (mapcar #'buffer-name buffers)
            :prompt "Waiting for input: "
            :category 'buffer
            :require-match t
            :sort nil
            :state (consult--buffer-preview))))
      (proc-notify--raise (get-buffer choice)))))

(declare-function consult--buffer-state "consult")

;;;###autoload
(defvar proc-notify-consult-source
  (list
   :name "Awaiting input"
   :category 'buffer
   :narrow ?!
   :face 'consult-buffer
   :history 'buffer-name-history
   :state #'consult--buffer-state
   :items
   (lambda () (mapcar #'buffer-name (proc-notify--awaiting-buffers))))
  "`consult-buffer' source listing buffers waiting for input.
Add to `consult-buffer-sources' to fold it into `consult-buffer' (narrow
with `!').")

;;;###autoload
(defun proc-notify-setup ()
  "Install password-prompt, needs-input and completion desktop notifications.
Covers comint (shell, `async-shell-command', sudo `compile') directly, and
notifies on `async-shell-command' completion via a `shell-command-sentinel'
advice.  Points claude-code's `claude-code-notification-function' at the
clickable `proc-notify' style, and routes our own (`proc-notify' category) and
plain-ghostel (`ghostel-mode') `alert's to it too, plus the ghostel
password-prompt path.  The claude-code and ghostel wiring is deferred until
those packages load.  Also tracks acknowledged buffers for the pull-side
`proc-notify-consult'."
  ;; Route only the alerts we care about to our style; everything else keeps
  ;; alert's own default, so this stays a good citizen for other packages.
  (alert-add-rule :category "proc-notify" :style 'proc-notify)
  (alert-add-rule :mode 'ghostel-mode :style 'proc-notify)
  (advice-add
   'comint-send-invisible
   :before #'proc-notify--password-advice)
  (advice-add
   'shell-command-sentinel
   :after #'proc-notify--shell-command-exit-advice)
  (add-hook 'comint-output-filter-functions #'proc-notify--arm-idle)
  (add-hook
   'window-selection-change-functions #'proc-notify--note-selection)
  (with-eval-after-load 'ghostel
    (proc-notify-ghostel-setup))
  (with-eval-after-load 'claude-code
    (proc-notify-claude-code-setup)))

(provide 'proc-notify)
;;; proc-notify.el ends here
