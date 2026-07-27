;;; agents-hud-test.el --- Tests for agents-hud -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for agents-hud's rendering-side logic: the attention-first sort,
;; project grouping (stable first-seen order), entry labels, status text
;; (including dead-with-exit-code), the sidebar/consult decoration, avy
;; quick-select, and the git HEAD-watch cache.  The session status model itself
;; (waiting predicate, state resolver, name parsers) lives in claude-session and
;; is tested in claude-session-test.el.  The live front-ends (sidebar window,
;; consult source) are NOT exercised here — they need ghostel / consult / a
;; graphical frame; the logic they render is all covered below.
;;
;; Run standalone:
;;   emacs --batch -L . -l ert -l agents-hud-test.el \
;;     -f ert-run-tests-batch-and-exit
;; The Nix build runs exactly this as the package `checkPhase'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agents-hud)

;; The waiting predicate, interaction-repaint guards, state resolver and
;; buffer-name parsers moved to claude-session; their tests live in
;; claude-session-test.el.  What remains here exercises agents-hud's own
;; rendering-side logic: sort, grouping, labels, status text, the sidebar/consult
;; decoration, avy, and the git HEAD-watch cache.

;;; --- helpers to build entries ------------------------------------------------

(defun agents-hud-test--entry (&rest kw)
  "Build a `agents-hud-entry' from keyword args KW for sort/format tests."
  (apply #'agents-hud-entry--create kw))

;;; --- attention-first sort ----------------------------------------------------

(ert-deftest agents-hud-test-sort-priority ()
  "Sort floats waiting above working above ready above dead."
  (let* ((ready
          (agents-hud-test--entry :state 'ready :project "/p/aaa"))
         (dead
          (agents-hud-test--entry :state 'dead :project "/p/bbb"))
         (wait
          (agents-hud-test--entry :state 'waiting :project "/p/ccc"))
         (work
          (agents-hud-test--entry :state 'working :project "/p/ddd"))
         (sorted
          (agents-hud--sort-entries (list ready dead wait work))))
    (should
     (equal
      (mapcar #'agents-hud-entry-state sorted)
      '(waiting working ready dead)))))

(ert-deftest agents-hud-test-sort-label-tiebreak ()
  "Same state sorts alphabetically by label."
  (let* ((b
          (agents-hud-test--entry :state 'ready :project "/p/zebra"))
         (a
          (agents-hud-test--entry :state 'ready :project "/p/alpha"))
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

(ert-deftest agents-hud-test-entry-name ()
  "The row name is the instance, else worktree, else repo, else path basename."
  ;; instance wins
  (should
   (equal
    "email"
    (agents-hud--entry-name
     (agents-hud-test--entry :instance "email" :worktree "feat/x"))))
  ;; no instance -> worktree tag
  (should
   (equal
    "feat/x"
    (agents-hud--entry-name
     (agents-hud-test--entry :worktree "feat/x" :branch "feat/x"))))
  ;; no instance/worktree -> repo basename
  (should
   (equal
    "nixos"
    (agents-hud--entry-name
     (agents-hud-test--entry :project "/home/me/code/nixos"))))
  ;; nothing but a path -> its basename
  (should
   (equal
    "logs"
    (agents-hud--entry-name
     (agents-hud-test--entry :path "/var/logs")))))

;;; --- grouping ----------------------------------------------------------------

(ert-deftest agents-hud-test-group-stable-order ()
  "Rows and groups keep first-seen order regardless of state (no reshuffle)."
  (let (bufs)
    (unwind-protect
        (let ((b1 (generate-new-buffer " ah1"))
              (b2 (generate-new-buffer " ah2"))
              (b3 (generate-new-buffer " ah3")))
          (setq bufs (list b1 b2 b3))
          ;; prime the first-seen sequence in creation order: b1 < b2 < b3
          (agents-hud--seq b1)
          (agents-hud--seq b2)
          (agents-hud--seq b3)
          (let*
              ((e1
                (agents-hud-test--entry
                 :buffer b1
                 :state 'ready
                 :project "/p/nixos"))
               (e2
                (agents-hud-test--entry
                 :buffer b2
                 :state 'waiting
                 :project "/p/music"))
               (e3
                (agents-hud-test--entry
                 :buffer b3
                 :state 'working
                 :project "/p/nixos"))
               ;; pass in a jumbled order — grouping must ignore it and state
               (groups
                (agents-hud--group-by-project (list e3 e2 e1))))
            (should (= 2 (length groups)))
            ;; group order follows the earliest member: nixos (b1) before music (b2)
            (should
             (equal '("/p/nixos" "/p/music") (mapcar #'car groups)))
            ;; within nixos: creation order b1 then b3 — NOT working-above-ready
            (should
             (equal
              (list b1 b3)
              (mapcar
               #'agents-hud-entry-buffer
               (cdr (assoc "/p/nixos" groups)))))))
      (mapc #'kill-buffer bufs))))

(ert-deftest agents-hud-test-seq-stable ()
  "A buffer keeps its sequence; a newly seen buffer gets a higher one."
  (let (bufs)
    (unwind-protect
        (let ((a (generate-new-buffer " ahs1"))
              (b (generate-new-buffer " ahs2")))
          (setq bufs (list a b))
          (let ((sa (agents-hud--seq a)))
            (should (= sa (agents-hud--seq a))) ; stable on re-lookup
            (should (> (agents-hud--seq b) sa)))) ; newcomer ranks later
      (mapc #'kill-buffer bufs))))

(ert-deftest agents-hud-test-group-no-project-key ()
  "A project-less entry groups under its path."
  (let* ((e
          (agents-hud-test--entry
           :state 'ready
           :project nil
           :path "/var/logs"))
         (groups (agents-hud--group-by-project (list e))))
    (should (equal "/var/logs" (car (car groups))))))

(ert-deftest agents-hud-test-group-collapsed ()
  "A group key reads collapsed only while present in the fold set."
  (let ((agents-hud--collapsed (make-hash-table :test 'equal)))
    (should-not (agents-hud--group-collapsed-p "/p/nixos"))
    (should-not (agents-hud--group-collapsed-p nil))
    (puthash "/p/nixos" t agents-hud--collapsed)
    (should (agents-hud--group-collapsed-p "/p/nixos"))
    (should-not (agents-hud--group-collapsed-p "/p/other"))))

(ert-deftest agents-hud-test-head-change ()
  "A HEAD change drops the branch/worktree caches; other git churn does not."
  (let ((agents-hud--branch-cache (make-hash-table :test 'equal))
        (agents-hud--worktree-cache (make-hash-table :test 'equal)))
    (puthash "/p" "main" agents-hud--branch-cache)
    (puthash "/p" "main" agents-hud--worktree-cache)
    ;; churn on a non-HEAD file (the index, a ref lock) — caches untouched
    (agents-hud--on-head-change '(desc changed "/repo/.git/index"))
    (should (= 1 (hash-table-count agents-hud--branch-cache)))
    ;; a HEAD rewrite (a branch switch) — both caches cleared
    (agents-hud--on-head-change '(desc changed "/repo/.git/HEAD"))
    (should (= 0 (hash-table-count agents-hud--branch-cache)))
    (should (= 0 (hash-table-count agents-hud--worktree-cache)))))

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
    "ready"
    (agents-hud--status-label
     (agents-hud-test--entry :state 'ready)))))

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
       (agents-hud-test--entry :state 'ready))))
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

;;; --- running-shell badge -----------------------------------------------------

(ert-deftest agents-hud-test-shell-badge ()
  "The shell badge is the glyph + count when shells>0, empty otherwise."
  (let ((agents-hud-shell-badge-icon "$"))
    (should
     (equal
      "$2"
      (agents-hud--shell-badge (agents-hud-test--entry :shells 2))))
    (should
     (equal
      "$1"
      (agents-hud--shell-badge (agents-hud-test--entry :shells 1))))
    (should
     (equal
      ""
      (agents-hud--shell-badge (agents-hud-test--entry :shells 0))))
    (should
     (equal
      ""
      (agents-hud--shell-badge
       (agents-hud-test--entry :shells nil))))))

;;; --- picker candidate decoration / recovery ----------------------------------

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

;;; --- avy quick-select --------------------------------------------------------

(ert-deftest agents-hud-test-entry-positions ()
  "One position is collected per session row, at the row's start."
  (with-temp-buffer
    (let ((ea (agents-hud-test--entry :state 'ready :project "/p/a"))
          (eb (agents-hud-test--entry :state 'ready :project "/p/b")))
      (insert "── heading\n")
      (let ((s1 (point)))
        (insert "  row-a\n     path\n")
        (put-text-property s1 (point) 'agents-hud-entry ea))
      (insert "\n── heading2\n")
      (let ((s2 (point)))
        (insert "  row-b\n     path\n")
        (put-text-property s2 (point) 'agents-hud-entry eb))
      (let ((positions
             (agents-hud--entry-positions (current-buffer))))
        (should (= 2 (length positions)))
        ;; each position carries its entry
        (should
         (eq
          ea (get-text-property (nth 0 positions) 'agents-hud-entry)))
        (should
         (eq
          eb
          (get-text-property
           (nth 1 positions) 'agents-hud-entry)))))))

(ert-deftest agents-hud-test-avy-keys-style ()
  "Key list runs in order: a b c … by default, 1 2 3 … 0 when numbers."
  (let ((agents-hud-avy-keys-style 'letters))
    (should (equal '(?a ?b ?c) (seq-take (agents-hud--avy-keys) 3)))
    (should (= 26 (length (agents-hud--avy-keys)))))
  (let ((agents-hud-avy-keys-style 'numbers))
    (should (equal '(?1 ?2 ?3) (seq-take (agents-hud--avy-keys) 3)))
    ;; 1-9 then 0 as the tenth label
    (should (equal '(?9 ?0) (last (agents-hud--avy-keys) 2)))))

(ert-deftest agents-hud-test-avy-action-jumps ()
  "The avy action reads the entry at PT in the HUD buffer and jumps to it."
  (let* ((target (generate-new-buffer " agents-hud-target"))
         (entry (agents-hud-test--entry :state 'ready :buffer target))
         (hud (get-buffer-create agents-hud--buffer-name))
         (jumped nil))
    (unwind-protect
        (progn
          (with-current-buffer hud
            (let ((inhibit-read-only t))
              (erase-buffer)
              (insert "  row\n     path\n")
              (put-text-property
               (point-min) (point-max) 'agents-hud-entry entry)))
          (cl-letf (((symbol-function 'agents-hud--goto-buffer)
                     (lambda (b) (setq jumped b))))
            (agents-hud--avy-action (point-min)))
          (should (eq target jumped)))
      (kill-buffer target)
      (when (buffer-live-p hud)
        (kill-buffer hud)))))

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
   (equal agents-hud-waiting-icon (agents-hud--state-icon 'waiting)))
  (should
   (equal agents-hud-ready-icon (agents-hud--state-icon 'ready)))
  (should (equal agents-hud-dead-icon (agents-hud--state-icon 'dead)))
  (should
   (eq 'agents-hud-waiting-face (agents-hud--state-face 'waiting)))
  (should
   (eq 'agents-hud-working-face (agents-hud--state-face 'working))))

(ert-deftest agents-hud-test-working-spinner ()
  "Working shows the current spinner frame, or the static icon with no frames."
  ;; frames advance with the index (modulo the frame count)
  (let ((agents-hud-working-frames '("a" "b" "c")))
    (let ((agents-hud--spinner-index 0))
      (should (equal "a" (agents-hud--state-icon 'working))))
    (let ((agents-hud--spinner-index 1))
      (should (equal "b" (agents-hud--state-icon 'working))))
    (let ((agents-hud--spinner-index 4)) ; wraps: 4 mod 3 = 1
      (should (equal "b" (agents-hud--state-icon 'working)))))
  ;; no frames -> the static working icon
  (let ((agents-hud-working-frames nil))
    (should
     (equal
      agents-hud-working-icon (agents-hud--state-icon 'working)))))

(provide 'agents-hud-test)
;;; agents-hud-test.el ends here
