;;; agents-hud-test.el --- Tests for agents-hud -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the pure / heuristic core of agents-hud: the waiting
;; predicate, the state resolver, the attention-first sort, project grouping,
;; duration formatting, status text (including dead-with-exit-code), and the
;; buffer-name parsers.  The live front-ends (sidebar window, consult source)
;; and the terminal hooks are NOT exercised here — they need ghostel / consult /
;; a graphical frame; the logic they render is all covered below.
;;
;; Run standalone:
;;   emacs --batch -L . -l ert -l agents-hud-test.el \
;;     -f ert-run-tests-batch-and-exit
;; The Nix build runs exactly this as the package `checkPhase'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agents-hud)

;;; --- waiting predicate -------------------------------------------------------

(ert-deftest agents-hud-test-waiting-from-pending ()
  "A pending buffer is waiting regardless of bell/activity."
  (should (agents-hud--waiting-p t nil nil))
  (should (agents-hud--waiting-p t 100.0 200.0)))

(ert-deftest agents-hud-test-waiting-from-bell ()
  "A bell with no output since it means waiting; later output clears it."
  ;; bell rang, no activity at all -> waiting
  (should (agents-hud--waiting-p nil 100.0 nil))
  ;; last activity was before the bell -> waiting
  (should (agents-hud--waiting-p nil 100.0 90.0))
  ;; activity after the bell (a new turn started) -> not waiting
  (should-not (agents-hud--waiting-p nil 100.0 110.0)))

(ert-deftest agents-hud-test-waiting-none ()
  "No pending and no bell is never waiting."
  (should-not (agents-hud--waiting-p nil nil 100.0)))

;;; --- state resolver ----------------------------------------------------------

(ert-deftest agents-hud-test-state-dead ()
  "A buffer with no live process is dead, whatever else is set."
  (should
   (eq
    'dead
    (agents-hud--compute-state
     :live nil
     :waiting t
     :activity 100.0
     :now 100.0)))
  (should
   (eq
    'dead
    (agents-hud--compute-state :live nil :cmd-running t :now 100.0))))

(ert-deftest agents-hud-test-state-waiting-beats-working ()
  "Waiting outranks working even with fresh activity."
  (should
   (eq
    'waiting
    (agents-hud--compute-state
     :live t
     :waiting t
     :activity 100.0
     :now 100.5
     :cutoff 3.0))))

(ert-deftest agents-hud-test-state-working-from-cmd ()
  "The OSC-133 command-running flag makes a buffer working."
  (should
   (eq
    'working
    (agents-hud--compute-state
     :live t
     :cmd-running t
     :activity nil
     :now 100.0))))

(ert-deftest agents-hud-test-state-working-from-activity ()
  "Recent redraw activity (within cutoff) is working."
  (should
   (eq
    'working
    (agents-hud--compute-state
     :live t
     :activity 99.0
     :now 100.0
     :cutoff 3.0))))

(ert-deftest agents-hud-test-state-idle ()
  "Live but quiet past the cutoff, not waiting, is idle."
  (should
   (eq
    'idle
    (agents-hud--compute-state
     :live t
     :activity 90.0
     :now 100.0
     :cutoff 3.0)))
  (should
   (eq
    'idle
    (agents-hud--compute-state :live t :activity nil :now 100.0))))

;;; --- helpers to build entries ------------------------------------------------

(defun agents-hud-test--entry (&rest kw)
  "Build a `agents-hud-entry' from keyword args KW for sort/format tests."
  (apply #'agents-hud-entry--create kw))

;;; --- attention-first sort ----------------------------------------------------

(ert-deftest agents-hud-test-sort-priority ()
  "Sort floats waiting above working above idle above dead."
  (let* ((idle
          (agents-hud-test--entry :state 'idle :project "/p/aaa"))
         (dead
          (agents-hud-test--entry :state 'dead :project "/p/bbb"))
         (wait
          (agents-hud-test--entry :state 'waiting :project "/p/ccc"))
         (work
          (agents-hud-test--entry :state 'working :project "/p/ddd"))
         (sorted
          (agents-hud--sort-entries (list idle dead wait work))))
    (should
     (equal
      (mapcar #'agents-hud-entry-state sorted)
      '(waiting working idle dead)))))

(ert-deftest agents-hud-test-sort-label-tiebreak ()
  "Same state sorts alphabetically by label."
  (let* ((b (agents-hud-test--entry :state 'idle :project "/p/zebra"))
         (a (agents-hud-test--entry :state 'idle :project "/p/alpha"))
         (sorted (agents-hud--sort-entries (list b a))))
    (should
     (equal
      (mapcar #'agents-hud--entry-label sorted) '("alpha" "zebra")))))

;;; --- entry label -------------------------------------------------------------

(ert-deftest agents-hud-test-label-plain ()
  "A project with no instance shows just the project name."
  (should
   (equal
    "nixos"
    (agents-hud--entry-label
     (agents-hud-test--entry :project "/home/me/code/nixos")))))

(ert-deftest agents-hud-test-label-instance ()
  "An instance suffix is appended as project:instance."
  (should
   (equal
    "nixos:review"
    (agents-hud--entry-label
     (agents-hud-test--entry
      :project "/home/me/code/nixos"
      :instance "review")))))

(ert-deftest agents-hud-test-label-no-project ()
  "With no project the path's last component is the label."
  (should
   (equal
    "logs"
    (agents-hud--entry-label
     (agents-hud-test--entry :project nil :path "/var/logs")))))

(ert-deftest agents-hud-test-label-worktree ()
  "The worktree tag qualifies the repo (flat) or leads the row (relative)."
  (let ((e
         (agents-hud-test--entry
          :project "/home/me/code/nixos"
          :worktree "stump"
          :instance "default")))
    ;; flat (consult): repo/worktree:instance
    (should (equal "nixos/stump:default" (agents-hud--entry-label e)))
    ;; relative (sidebar, under the nixos heading): worktree:instance
    (should (equal "stump:default" (agents-hud--entry-label e t)))))

(ert-deftest agents-hud-test-label-worktree-branch ()
  "A main-worktree tag (a branch name) disambiguates from sibling worktrees."
  (let ((e
         (agents-hud-test--entry
          :project "/home/me/code/nixos"
          :worktree "feat/backups-board")))
    (should
     (equal "nixos/feat/backups-board" (agents-hud--entry-label e)))
    (should
     (equal "feat/backups-board" (agents-hud--entry-label e t)))))

;;; --- grouping ----------------------------------------------------------------

(ert-deftest agents-hud-test-group-by-project ()
  "Entries collect under their project key; a waiting group sorts first."
  (let* ((n1
          (agents-hud-test--entry :state 'idle :project "/p/nixos"))
         (n2
          (agents-hud-test--entry
           :state 'working
           :project "/p/nixos"))
         (m1
          (agents-hud-test--entry
           :state 'waiting
           :project "/p/music"))
         (groups (agents-hud--group-by-project (list n1 n2 m1))))
    ;; two groups
    (should (= 2 (length groups)))
    ;; the group containing the waiting session comes first
    (should (equal "/p/music" (car (car groups))))
    ;; within nixos, working floats above idle
    (let ((nixos (assoc "/p/nixos" groups)))
      (should
       (equal
        '(working idle)
        (mapcar #'agents-hud-entry-state (cdr nixos)))))))

(ert-deftest agents-hud-test-group-no-project-key ()
  "A project-less entry groups under its path."
  (let* ((e
          (agents-hud-test--entry
           :state 'idle
           :project nil
           :path "/var/logs"))
         (groups (agents-hud--group-by-project (list e))))
    (should (equal "/var/logs" (car (car groups))))))

;;; --- status label (no timing) ------------------------------------------------

(ert-deftest agents-hud-test-status-label ()
  "The status label is the bare state word, no duration."
  (should
   (equal
    "working"
    (agents-hud--status-label
     (agents-hud-test--entry :state 'working))))
  (should
   (equal
    "waiting"
    (agents-hud--status-label
     (agents-hud-test--entry :state 'waiting))))
  (should
   (equal
    "idle"
    (agents-hud--status-label
     (agents-hud-test--entry :state 'idle)))))

(ert-deftest agents-hud-test-status-label-dead-exit ()
  "A dead entry's label carries its exit code when known, else a bare word."
  (should
   (equal
    "exited (0)"
    (agents-hud--status-label
     (agents-hud-test--entry :state 'dead :exit 0))))
  (should
   (equal
    "exited (1)"
    (agents-hud--status-label
     (agents-hud-test--entry :state 'dead :exit 1))))
  (should
   (equal
    "exited"
    (agents-hud--status-label
     (agents-hud-test--entry :state 'dead :exit nil)))))

;;; --- sidebar status column (icon-first, optional word) -----------------------

(ert-deftest agents-hud-test-sidebar-status-icons-only ()
  "With the label off, the status column is empty except a dead exit code."
  (let ((agents-hud-show-state-label nil))
    (should
     (equal
      ""
      (agents-hud--sidebar-status
       (agents-hud-test--entry :state 'working :since 88.0))))
    (should
     (equal
      ""
      (agents-hud--sidebar-status
       (agents-hud-test--entry :state 'idle))))
    ;; a dead exit code is still surfaced (no icon conveys it)
    (should
     (equal
      "(1)"
      (agents-hud--sidebar-status
       (agents-hud-test--entry :state 'dead :exit 1))))
    (should
     (equal
      ""
      (agents-hud--sidebar-status
       (agents-hud-test--entry :state 'dead :exit nil))))))

(ert-deftest agents-hud-test-sidebar-status-with-label ()
  "With the label on, the status column spells out the state (still no time)."
  (let ((agents-hud-show-state-label t))
    (should
     (equal
      "working"
      (agents-hud--sidebar-status
       (agents-hud-test--entry :state 'working :since 88.0))))
    (should
     (equal
      "exited (1)"
      (agents-hud--sidebar-status
       (agents-hud-test--entry :state 'dead :exit 1))))))

;;; --- picker candidate decoration / recovery ----------------------------------

(ert-deftest agents-hud-test-type-icon-fallback ()
  "Without nerd-icons the type icon falls back to the plain glyph."
  ;; nerd-icons is not loaded in the test image, so fboundp is nil.
  (should
   (equal agents-hud-claude-glyph (agents-hud--type-icon 'claude)))
  (should
   (equal agents-hud-shell-glyph (agents-hud--type-icon 'shell))))

(ert-deftest agents-hud-test-consult-candidates ()
  "Consult candidates are the live buffers' plain names (attention-sorted)."
  (let (bufs)
    (unwind-protect
        (progn
          ;; the collector recognises buffers by ghostel-mode or a *claude:* name
          (unless (fboundp 'ghostel-mode)
            (define-derived-mode
             ghostel-mode fundamental-mode "Ghostel"))
          (dolist (n '("*claude:/tmp/:a*" "*ghostel: b*"))
            (let ((b (get-buffer-create n)))
              (with-current-buffer b
                (ghostel-mode)
                (setq default-directory "/tmp/"))
              (push b bufs)))
          (let ((cands (agents-hud--consult-candidates)))
            (should (= 2 (length cands)))
            ;; plain buffer names, each resolving to a real buffer
            (should (cl-every #'get-buffer cands))))
      (mapc #'kill-buffer bufs))))

(ert-deftest agents-hud-test-nerd-icon-advice ()
  "The buffer-icon advice picks Claude vs shell by name/mode, else defers."
  (cl-letf (((symbol-function 'nerd-icons-mdicon)
             (lambda (name &rest _) (concat "M:" name)))
            ((symbol-function 'nerd-icons-faicon)
             (lambda (name &rest _) (concat "F:" name))))
    (let ((orig (lambda (&rest _) 'fallback)))
      (unless (fboundp 'ghostel-mode)
        (define-derived-mode ghostel-mode fundamental-mode "Ghostel"))
      ;; a *claude:* buffer gets the Claude mdicon
      (let ((b (get-buffer-create "*claude:/x/:a*")))
        (unwind-protect
            (with-current-buffer b
              (should
               (equal
                (concat "M:" agents-hud-claude-icon)
                (agents-hud--nerd-icon-for-buffer orig :height 1))))
          (kill-buffer b)))
      ;; a plain ghostel-mode buffer gets the shell faicon
      (let ((b (get-buffer-create "*ghostel: s*")))
        (unwind-protect
            (with-current-buffer b
              (ghostel-mode)
              (should
               (equal
                (concat "F:" agents-hud-shell-icon)
                (agents-hud--nerd-icon-for-buffer orig :height 1))))
          (kill-buffer b)))
      ;; anything else falls through to the original function
      (with-temp-buffer
        (should
         (eq 'fallback (agents-hud--nerd-icon-for-buffer orig)))))))

;;; --- icons / faces -----------------------------------------------------------

(ert-deftest agents-hud-test-state-icon-face ()
  "Each state maps to its configured icon and a distinct face."
  (should
   (equal agents-hud-working-icon (agents-hud--state-icon 'working)))
  (should
   (equal agents-hud-waiting-icon (agents-hud--state-icon 'waiting)))
  (should (equal agents-hud-idle-icon (agents-hud--state-icon 'idle)))
  (should (equal agents-hud-dead-icon (agents-hud--state-icon 'dead)))
  (should
   (eq 'agents-hud-waiting-face (agents-hud--state-face 'waiting)))
  (should
   (eq 'agents-hud-working-face (agents-hud--state-face 'working))))

;;; --- buffer-name parsing -----------------------------------------------------

(ert-deftest agents-hud-test-instance-claude ()
  "The instance name is parsed from a claude buffer name suffix."
  (with-temp-buffer
    (rename-buffer "*claude:/home/me/code/nixos/:review*" t)
    (should
     (equal
      "review"
      (agents-hud--buffer-instance (current-buffer) 'claude))))
  (with-temp-buffer
    (rename-buffer "*claude:/home/me/code/nixos/*" t)
    (should
     (null (agents-hud--buffer-instance (current-buffer) 'claude)))))

(ert-deftest agents-hud-test-instance-ghostel ()
  "The title is parsed from a plain ghostel buffer name."
  (with-temp-buffer
    (rename-buffer "*ghostel: rk1b*" t)
    (should
     (equal
      "rk1b" (agents-hud--buffer-instance (current-buffer) 'shell)))))

(ert-deftest agents-hud-test-buffer-type ()
  "Buffer type is claude for *claude:* names, shell otherwise."
  (with-temp-buffer
    (rename-buffer "*claude:/x/*" t)
    (should (eq 'claude (agents-hud--buffer-type (current-buffer)))))
  (with-temp-buffer
    (rename-buffer "*ghostel: sh*" t)
    (should (eq 'shell (agents-hud--buffer-type (current-buffer))))))

(provide 'agents-hud-test)
;;; agents-hud-test.el ends here
