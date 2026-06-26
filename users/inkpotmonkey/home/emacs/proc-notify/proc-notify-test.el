;;; proc-notify-test.el --- Tests for proc-notify -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the pure / heuristic helpers in proc-notify: the needs-input
;; prompt detector, the notification filter, the severity→urgency mapping, the
;; pending-set bookkeeping (remember / forget / acknowledge), and the
;; awaiting-buffers query.  The D-Bus and window-raising paths are deliberately
;; NOT exercised here (they need a session bus and a graphical frame); the one
;; place a test crosses into them — `proc-notify--acknowledge' closing a toast —
;; stubs `notifications-close-notification'.
;;
;; Run standalone:
;;   emacs --batch -L . -L <deps...> -l ert \
;;     -l proc-notify-test.el -f ert-run-tests-batch-and-exit
;; The Nix build runs exactly this as the package `checkPhase'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'proc-notify)

;;; --- needs-input prompt heuristic -------------------------------------------

(defun proc-notify-test--prompt-p (text)
  "Return `proc-notify--looks-like-prompt-p' for a buffer holding TEXT."
  (with-temp-buffer
    (insert text)
    (proc-notify--looks-like-prompt-p)))

(ert-deftest proc-notify-test-prompt-question ()
  "A line ending in `?' is a prompt."
  (should (proc-notify-test--prompt-p "Continue?"))
  (should (proc-notify-test--prompt-p "Overwrite existing file? ")))

(ert-deftest proc-notify-test-prompt-colon ()
  "A line ending in `:' is a prompt (covers `[sudo] password for …:')."
  (should (proc-notify-test--prompt-p "Enter your name:"))
  (should (proc-notify-test--prompt-p "[sudo] password for thomas:")))

(ert-deftest proc-notify-test-prompt-yes-no ()
  "`[y/n]' / `(yes/no)' style queries are prompts."
  (should (proc-notify-test--prompt-p "Proceed [y/n]"))
  (should (proc-notify-test--prompt-p "Delete it? [Y/n] "))
  (should (proc-notify-test--prompt-p "Are you sure (yes/no)")))

(ert-deftest proc-notify-test-prompt-rejects-shell-prompts ()
  "Idle interactive shell prompts must NOT register as needs-input."
  (should-not (proc-notify-test--prompt-p "user@host:~$ "))
  (should-not (proc-notify-test--prompt-p "nix-shell% "))
  (should-not (proc-notify-test--prompt-p "root# "))
  (should-not (proc-notify-test--prompt-p "PS> ")))

(ert-deftest proc-notify-test-prompt-rejects-terminated ()
  "A finished line (trailing newline) or empty buffer is not awaiting input."
  (should-not (proc-notify-test--prompt-p "Continue?\n"))
  (should-not (proc-notify-test--prompt-p "just some output\n"))
  (should-not (proc-notify-test--prompt-p "")))

;;; --- notification filtering -------------------------------------------------

(ert-deftest proc-notify-test-allow-default ()
  "With no filters configured, everything is allowed."
  (let ((proc-notify-ignore-regexps nil)
        (proc-notify-filter-function nil))
    (should (proc-notify--allow-p "Title" "Body" (current-buffer)))))

(ert-deftest proc-notify-test-allow-ignore-regexp ()
  "An ignore regexp drops matching \"TITLE: BODY\", passes non-matching."
  (let ((proc-notify-ignore-regexps '("turn complete"))
        (proc-notify-filter-function nil))
    (should-not
     (proc-notify--allow-p "Claude" "turn complete" (current-buffer)))
    (should
     (proc-notify--allow-p "Claude" "needs input" (current-buffer)))))

(ert-deftest proc-notify-test-allow-ignore-case-insensitive ()
  "Ignore matching is case-insensitive."
  (let ((proc-notify-ignore-regexps '("CLAUDE"))
        (proc-notify-filter-function nil))
    (should-not
     (proc-notify--allow-p "claude code" "ping" (current-buffer)))))

(ert-deftest proc-notify-test-allow-filter-function ()
  "`proc-notify-filter-function' gates allow/deny."
  (let ((proc-notify-ignore-regexps nil)
        (proc-notify-filter-function
         (lambda (title _body _buf) (string-prefix-p "Allow" title))))
    (should (proc-notify--allow-p "Allow me" "x" (current-buffer)))
    (should-not
     (proc-notify--allow-p "Block me" "x" (current-buffer)))))

;;; --- severity → urgency -----------------------------------------------------

(ert-deftest proc-notify-test-severity-mapping ()
  "alert severities map onto the three freedesktop urgencies."
  (should (eq (proc-notify--severity->urgency 'urgent) 'critical))
  (should (eq (proc-notify--severity->urgency 'high) 'critical))
  (should (eq (proc-notify--severity->urgency 'low) 'low))
  (should (eq (proc-notify--severity->urgency 'trivial) 'low))
  (should (eq (proc-notify--severity->urgency 'normal) 'normal))
  (should (eq (proc-notify--severity->urgency 'moderate) 'normal))
  (should (eq (proc-notify--severity->urgency nil) 'normal)))

;;; --- pending-set bookkeeping ------------------------------------------------

(ert-deftest proc-notify-test-remember-forget ()
  "`remember' is idempotent; `forget' removes."
  (let ((proc-notify--pending nil)
        (buf (generate-new-buffer " *pn-rf*")))
    (unwind-protect
        (progn
          (proc-notify--remember buf)
          (should (memq buf proc-notify--pending))
          (proc-notify--remember buf)
          (should (= 1 (length proc-notify--pending)))
          (proc-notify--forget buf)
          (should-not (memq buf proc-notify--pending)))
      (kill-buffer buf))))

(ert-deftest proc-notify-test-remember-skips-dead ()
  "A dead buffer is never remembered."
  (let ((proc-notify--pending nil)
        (buf (generate-new-buffer " *pn-dead*")))
    (kill-buffer buf)
    (proc-notify--remember buf)
    (should-not (memq buf proc-notify--pending))))

(ert-deftest proc-notify-test-acknowledge-closes-and-clears ()
  "`acknowledge' closes the toast by id, clears the id, and forgets the buffer."
  (let ((proc-notify--pending nil)
        (buf (generate-new-buffer " *pn-ack*"))
        (closed nil))
    (unwind-protect
        (cl-letf (((symbol-function 'notifications-close-notification)
                   (lambda (id &rest _) (push id closed))))
          (with-current-buffer buf
            (setq proc-notify--id 42))
          (proc-notify--remember buf)
          (proc-notify--acknowledge buf)
          (should (equal closed '(42)))
          (should-not (buffer-local-value 'proc-notify--id buf))
          (should-not (memq buf proc-notify--pending)))
      (kill-buffer buf))))

(ert-deftest proc-notify-test-acknowledge-without-id ()
  "With no stored id, `acknowledge' forgets but does not call close."
  (let ((proc-notify--pending nil)
        (buf (generate-new-buffer " *pn-ack2*"))
        (called nil))
    (unwind-protect
        (cl-letf (((symbol-function 'notifications-close-notification)
                   (lambda (&rest _) (setq called t))))
          (proc-notify--remember buf)
          (proc-notify--acknowledge buf)
          (should-not called)
          (should-not (memq buf proc-notify--pending)))
      (kill-buffer buf))))

;;; --- awaiting-buffers query -------------------------------------------------

(ert-deftest proc-notify-test-awaiting-prunes-dead ()
  "Dead buffers are pruned from the awaiting set."
  (let* ((live (generate-new-buffer " *pn-live*"))
         (dead (generate-new-buffer " *pn-dead2*"))
         (proc-notify--pending (list live dead)))
    (unwind-protect
        (progn
          (kill-buffer dead)
          (cl-letf (((symbol-function 'proc-notify--watching-p)
                     (lambda (_b) nil)))
            (let ((awaiting (proc-notify--awaiting-buffers)))
              (should (memq live awaiting))
              (should-not (memq dead awaiting)))))
      (when (buffer-live-p live)
        (kill-buffer live)))))

(ert-deftest proc-notify-test-awaiting-excludes-watched ()
  "A buffer you are already watching is excluded from the awaiting set."
  (let* ((watched (generate-new-buffer " *pn-watched*"))
         (proc-notify--pending (list watched)))
    (unwind-protect
        (cl-letf (((symbol-function 'proc-notify--watching-p)
                   (lambda (b) (eq b watched))))
          (should-not (memq watched (proc-notify--awaiting-buffers))))
      (kill-buffer watched))))

;;; --- summary label ----------------------------------------------------------

(ert-deftest proc-notify-test-summary-prefers-command ()
  "`summary' uses the recorded async-shell command when present."
  (with-temp-buffer
    (setq-local async-shell-history--command "make build")
    (should
     (equal "make build" (proc-notify--summary (current-buffer))))))

(ert-deftest proc-notify-test-summary-falls-back-to-name ()
  "`summary' falls back to the buffer name."
  (let ((buf (generate-new-buffer "pn-summary-name")))
    (unwind-protect
        (should (equal "pn-summary-name" (proc-notify--summary buf)))
      (kill-buffer buf))))

(provide 'proc-notify-test)
;;; proc-notify-test.el ends here
