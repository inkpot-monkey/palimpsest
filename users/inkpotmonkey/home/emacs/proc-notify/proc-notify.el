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
;; Two triggers, installed together by `proc-notify-setup':
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
;; leaves every other package's alerts on alert's default.  OSC notifications can
;; be chatty (Claude pings per turn); narrow them with `proc-notify-ignore-regexps'
;; (simple) or `alert-add-rule' (richer).
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

(defun proc-notify--remember (buffer)
  "Record BUFFER as awaiting attention."
  (when (and (buffer-live-p buffer)
             (not (memq buffer proc-notify--pending)))
    (push buffer proc-notify--pending)))

(defun proc-notify--forget (buffer)
  "Drop BUFFER from the awaiting-attention set (it has been dealt with)."
  (setq proc-notify--pending (delq buffer proc-notify--pending)))

(defun proc-notify--note-selection (&rest _)
  "Acknowledge the selected window's buffer, clearing any pending flag.
Installed on `window-selection-change-functions' so visiting a flagged
buffer by any means drops it from `proc-notify--pending'."
  (proc-notify--forget (window-buffer (selected-window))))

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
  (proc-notify--forget buffer)
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

(defun proc-notify--notify (buffer title body &optional urgency)
  "Raise (or replace) a desktop notification for BUFFER.
TITLE and BODY are the notification text; URGENCY is a `notifications-notify'
urgency symbol.  Activating it runs `proc-notify--raise' on BUFFER.  A missing
D-Bus session bus is swallowed so headless/tty sessions stay quiet."
  (condition-case nil
      (let ((id
             (notifications-notify
              :app-name proc-notify-app-name
              :title title
              :body (format "%s" body)
              :replaces-id
              (buffer-local-value 'proc-notify--id buffer)
              :urgency (or urgency 'normal)
              :actions '("default" "Open")
              :on-action
              (lambda (&rest _) (proc-notify--raise buffer)))))
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

(defun proc-notify--password-advice (&rest _)
  "Before `comint-send-invisible' blocks on a password, emit a notification."
  (let ((buffer (current-buffer)))
    (when (derived-mode-p 'comint-mode)
      (proc-notify--emit
       buffer "Password required" (proc-notify--summary buffer)
       'high))))

;;; --- Process needs input ----------------------------------------------------

(defun proc-notify--idle-check (buffer)
  "Emit a needs-input notification if BUFFER's process is parked at a prompt."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((proc (get-buffer-process buffer)))
        (when (and proc
                   (process-live-p proc)
                   (proc-notify--looks-like-prompt-p))
          (proc-notify--emit
           buffer
           "Process waiting for input"
           (proc-notify--summary buffer)))))))

(defun proc-notify--looks-like-prompt-p ()
  "Non-nil when the buffer ends in an unterminated, prompt-shaped line."
  (save-excursion
    (goto-char (point-max))
    (and
     (not (bolp)) ; unterminated last line — a process awaiting input
     (string-match-p
      proc-notify-prompt-regexp
      (buffer-substring-no-properties
       (line-beginning-position) (point-max))))))

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

;;; --- ghostel / terminal bridge ----------------------------------------------

;; ghostel (the claude-code backend) is a libghostty PTY terminal, not comint,
;; so none of the comint hooks above reach it.  Two paths cover it:
;;
;;   * OSC 9/777 notifications (which Claude Code emits) need no glue here.
;;     ghostel's own `ghostel-default-notify' already calls `alert', and
;;     `proc-notify-setup' adds an `alert' rule routing `ghostel-mode' alerts to
;;     the `proc-notify' style — so they become clickable, raise-the-buffer
;;     popups like everything else, filtered by the same knobs.
;;
;;   * Password prompts are NOT notifications; ghostel reads them via
;;     `ghostel-password-prompt-functions'.  We add a source there that emits a
;;     notification and then returns nil, deferring to the real `read-passwd'.

(defun proc-notify-ghostel-password-source (row)
  "Notify on a ghostel password prompt, then defer to the real reader.
For `ghostel-password-prompt-functions': always returns nil so the normal
`read-passwd' (or a later auth source) still handles entry.  ROW is the
trimmed cursor-row text at detection."
  (proc-notify--emit (current-buffer)
                     "Password required"
                     (or row (proc-notify--summary (current-buffer)))
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
buffer when the toast is activated.  Severity `high' (Claude is blocked on you).
Keeps claude-code's own modeline pulse when available."
  (proc-notify--emit (current-buffer) title message 'high)
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
  "Install password-prompt and needs-input desktop notifications.
Covers comint (shell, `async-shell-command', sudo `compile') directly.  Points
claude-code's `claude-code-notification-function' at the clickable `proc-notify'
style, and routes our own (`proc-notify' category) and plain-ghostel
\(`ghostel-mode') `alert's to it too, plus the ghostel password-prompt path.
The claude-code and ghostel wiring is deferred until those packages load.  Also
tracks acknowledged buffers for the pull-side `proc-notify-consult'."
  ;; Route only the alerts we care about to our style; everything else keeps
  ;; alert's own default, so this stays a good citizen for other packages.
  (alert-add-rule :category "proc-notify" :style 'proc-notify)
  (alert-add-rule :mode 'ghostel-mode :style 'proc-notify)
  (advice-add
   'comint-send-invisible
   :before #'proc-notify--password-advice)
  (add-hook 'comint-output-filter-functions #'proc-notify--arm-idle)
  (add-hook
   'window-selection-change-functions #'proc-notify--note-selection)
  (with-eval-after-load 'ghostel
    (proc-notify-ghostel-setup))
  (with-eval-after-load 'claude-code
    (proc-notify-claude-code-setup)))

(provide 'proc-notify)
;;; proc-notify.el ends here
