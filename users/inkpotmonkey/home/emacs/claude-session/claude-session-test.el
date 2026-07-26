;;; claude-session-test.el --- Tests for claude-session -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the pure / heuristic core of claude-session: the waiting
;; predicate (live-screen scan), the interaction-repaint suppression guards, the
;; state resolver, and the buffer-name parsers.  The ghostel signal-collection
;; hooks are NOT exercised here — they need ghostel and a live terminal; the
;; logic they feed is all covered below.
;;
;; Run standalone:
;;   emacs --batch -L . -l ert -l claude-session-test.el \
;;     -f ert-run-tests-batch-and-exit
;; The Nix build runs exactly this as the package `checkPhase'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-session)

;;; --- waiting = selection prompt on screen ------------------------------------

(ert-deftest claude-session-test-selection-prompt ()
  "The live-screen scan matches a Claude Code picker, not the idle input box."
  (with-temp-buffer
    ;; idle input box: `❯' followed by placeholder text, mode footer -> no
    (insert
     "some earlier output\n"
     "❯ Try \"refactor init.el\"\n"
     "  ⏵⏵ auto mode on (shift+tab to cycle)\n")
    (should-not (claude-session--selection-prompt-p (current-buffer)))
    ;; a live selection prompt at the bottom -> yes (caret on a number + footer)
    (erase-buffer)
    (insert
     "What should I do with the file?\n"
     "❯ 1. Discard it (Recommended)\n"
     "  2. Keep & fix in place\n"
     "  3. Leave it for now\n"
     "Enter to select · Tab/Arrow keys to navigate · Esc to cancel\n")
    (should (claude-session--selection-prompt-p (current-buffer)))))

(ert-deftest claude-session-test-selection-prompt-scrollback ()
  "A prompt scrolled up out of the live screen is not counted as waiting."
  (with-temp-buffer
    (let ((claude-session-selection-scan-lines 10))
      (insert
       "❯ 1. An option you already chose\n"
       "Enter to select · Esc to cancel\n")
      ;; push it above the scan window with plain output, end at an idle box
      (dotimes (i 20)
        (insert (format "idle output line %d\n" i)))
      (insert
       "❯ Try \"something\"\n  ⏸ manual mode on · ? for shortcuts\n")
      (should-not
       (claude-session--selection-prompt-p (current-buffer))))))

;;; --- interaction-repaint suppression -----------------------------------------

(ert-deftest claude-session-test-latest-time ()
  "`claude-session--latest-time' returns the largest non-nil stamp, else nil."
  (should (= 5.0 (claude-session--latest-time 3.0 5.0 1.0)))
  (should (= 5.0 (claude-session--latest-time nil 5.0 nil)))
  (should (= 5.0 (claude-session--latest-time 5.0)))
  (should (null (claude-session--latest-time nil nil)))
  (should (null (claude-session--latest-time))))

(ert-deftest claude-session-test-interaction-suppressed ()
  "An interaction-window redraw on a quiet buffer is swallowed; an active one not.
The interaction time is a focus change or a keystroke (the caller passes the
later of the two).  Args: NOW INTERACTION ACTIVITY GRACE CUTOFF (0.4, 3.0)."
  ;; interaction 0.1s ago, buffer quiet (last activity 10s ago) -> suppress
  (should
   (claude-session--interaction-suppressed-p 100.0 99.9 90.0 0.4 3.0))
  ;; interaction 0.1s ago, buffer quiet, never had activity -> suppress
  (should
   (claude-session--interaction-suppressed-p 100.0 99.9 nil 0.4 3.0))
  ;; interaction 0.1s ago BUT buffer already active (0.2s ago) -> do NOT suppress
  (should-not
   (claude-session--interaction-suppressed-p 100.0 99.9 99.8 0.4 3.0))
  ;; quiet buffer but interaction was long ago (1s > grace) -> do NOT suppress
  (should-not
   (claude-session--interaction-suppressed-p 100.0 99.0 90.0 0.4 3.0))
  ;; no interaction recorded -> never suppress
  (should-not
   (claude-session--interaction-suppressed-p 100.0 nil 90.0 0.4 3.0))
  ;; grace disabled (0) -> never suppress
  (should-not
   (claude-session--interaction-suppressed-p 100.0 99.9 90.0 0 3.0)))

(ert-deftest claude-session-test-focus-rollback ()
  "A repaint stamp that landed just before a focus change is rolled back.
Args: NOW ACTIVITY ACTIVITY-PREV GRACE CUTOFF (grace 0.4, cutoff 3.0).  Models
the display repaint firing ~ms before `ghostel--focus-change'."
  ;; stamped 0.02s ago, was quiet before (prev 90s back) -> roll back
  (should (claude-session--focus-rollback-p 100.0 99.98 10.0 0.4 3.0))
  ;; stamped 0.02s ago, never had prior activity -> roll back
  (should (claude-session--focus-rollback-p 100.0 99.98 nil 0.4 3.0))
  ;; stamped 0.02s ago BUT was already active before (prev 0.1s earlier) -> keep
  (should-not
   (claude-session--focus-rollback-p 100.0 99.98 99.88 0.4 3.0))
  ;; last stamp is old (1s > grace) -> nothing recent to undo
  (should-not
   (claude-session--focus-rollback-p 100.0 99.0 10.0 0.4 3.0))
  ;; no activity at all -> nothing to undo
  (should-not
   (claude-session--focus-rollback-p 100.0 nil nil 0.4 3.0))
  ;; grace disabled (0) -> never roll back
  (should-not
   (claude-session--focus-rollback-p 100.0 99.98 10.0 0 3.0)))

;;; --- state resolver ----------------------------------------------------------

(ert-deftest claude-session-test-state-dead ()
  "A buffer with no live process is dead, whatever else is set."
  (should
   (eq
    'dead
    (claude-session--compute-state
     :live nil
     :waiting t
     :activity 100.0
     :now 100.0)))
  (should
   (eq
    'dead
    (claude-session--compute-state
     :live nil
     :cmd-running t
     :now 100.0))))

(ert-deftest claude-session-test-state-waiting-beats-working ()
  "Waiting outranks working even with fresh activity."
  (should
   (eq
    'waiting
    (claude-session--compute-state
     :live t
     :waiting t
     :activity 100.0
     :now 100.5
     :cutoff 3.0))))

(ert-deftest claude-session-test-state-working-from-cmd ()
  "The OSC-133 command-running flag makes a buffer working."
  (should
   (eq
    'working
    (claude-session--compute-state
     :live t
     :cmd-running t
     :activity nil
     :now 100.0))))

(ert-deftest claude-session-test-state-working-from-activity ()
  "Recent redraw activity (within cutoff) is working."
  (should
   (eq
    'working
    (claude-session--compute-state
     :live t
     :activity 99.0
     :now 100.0
     :cutoff 3.0))))

(ert-deftest claude-session-test-state-ready ()
  "Live but quiet past the cutoff, not waiting, is ready."
  (should
   (eq
    'ready
    (claude-session--compute-state
     :live t
     :activity 90.0
     :now 100.0
     :cutoff 3.0)))
  (should
   (eq
    'ready
    (claude-session--compute-state
     :live t
     :activity nil
     :now 100.0))))

;;; --- buffer-name parsing -----------------------------------------------------

(ert-deftest claude-session-test-instance-claude ()
  "The instance name is parsed from a claude buffer name suffix."
  (with-temp-buffer
    (rename-buffer "*claude:/home/me/code/nixos/:review*" t)
    (should
     (equal
      "review"
      (claude-session--buffer-instance (current-buffer) 'claude))))
  (with-temp-buffer
    (rename-buffer "*claude:/home/me/code/nixos/*" t)
    (should
     (null
      (claude-session--buffer-instance (current-buffer) 'claude)))))

(ert-deftest claude-session-test-instance-ghostel ()
  "The title is parsed from a plain ghostel buffer name."
  (with-temp-buffer
    (rename-buffer "*ghostel: rk1b*" t)
    (should
     (equal
      "rk1b"
      (claude-session--buffer-instance (current-buffer) 'shell)))))

(ert-deftest claude-session-test-buffer-type ()
  "Buffer type is claude for *claude:* names, shell otherwise."
  (with-temp-buffer
    (rename-buffer "*claude:/x/*" t)
    (should
     (eq 'claude (claude-session--buffer-type (current-buffer)))))
  (with-temp-buffer
    (rename-buffer "*ghostel: sh*" t)
    (should
     (eq 'shell (claude-session--buffer-type (current-buffer))))))

(provide 'claude-session-test)
;;; claude-session-test.el ends here
