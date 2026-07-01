;;; project-agent-test.el --- ERT tests for project-agent -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for the pure helpers and file-based operations in project-agent.
;; Deliberately excluded: the backend protocol, session browser, and
;; transient menu — those need a live process or interactive frame.
;;
;; Run standalone:
;;   emacs --batch -L . -l ert -l project-agent-test.el \
;;         -f ert-run-tests-batch-and-exit
;; The Nix build runs exactly this as the package checkPhase.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'project-agent)

;;; ── Helpers ─────────────────────────────────────────────────────────────────

(defmacro project-agent-test--with-project (&rest body)
  "Run BODY with a temporary project root bound to `root'."
  `(let ((root (make-temp-file "pa-test-" t)))
     (make-directory (expand-file-name ".agent" root) t)
     (unwind-protect
         (progn
           ,@body)
       (delete-directory root t))))

(defun project-agent-test--from (iso8601)
  "Parse \"YYYY-MM-DDTHH:MM:SSZ\" to a UTC time value using encode-time."
  (string-match
   (concat
    "\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)"
    "T\\([0-9]\\{2\\}\\):\\([0-9]\\{2\\}\\):\\([0-9]\\{2\\}\\)Z")
   iso8601)
  (encode-time
   (list
    (string-to-number (match-string 6 iso8601))
    (string-to-number (match-string 5 iso8601))
    (string-to-number (match-string 4 iso8601))
    (string-to-number (match-string 3 iso8601))
    (string-to-number (match-string 2 iso8601))
    (string-to-number (match-string 1 iso8601))
    nil
    nil
    0)))

(defun project-agent-test--fmt (time)
  "Format TIME as \"YYYY-MM-DD HH:MM\" UTC."
  (format-time-string "%Y-%m-%d %H:%M" time t))

;;; ── Frontmatter parser ──────────────────────────────────────────────────────

(ert-deftest project-agent-test-frontmatter-scalar ()
  "Plain scalar values are returned as strings."
  (let ((fm
         (project-agent--parse-frontmatter
          "---\nname: My Skill\nmode: batch\n---\n")))
    (should (equal "My Skill" (plist-get fm :name)))
    (should (equal "batch" (plist-get fm :mode)))))

(ert-deftest project-agent-test-frontmatter-quoted ()
  "Surrounding double-quotes are stripped from quoted scalars."
  (let ((fm
         (project-agent--parse-frontmatter
          "---\nschedule: \"0 9 * * 1\"\n---\n")))
    (should (equal "0 9 * * 1" (plist-get fm :schedule)))))

(ert-deftest project-agent-test-frontmatter-list ()
  "Indented list items accumulate into a Lisp list under their key."
  (let ((fm
         (project-agent--parse-frontmatter
          "---\ntools:\n  - web-search\n  - computer\n---\n")))
    (should
     (equal '("web-search" "computer") (plist-get fm :tools)))))

(ert-deftest project-agent-test-frontmatter-single-item-list ()
  "A single-item list still produces a list, not a bare string."
  (let ((fm
         (project-agent--parse-frontmatter
          "---\ntools:\n  - web-search\n---\n")))
    (should (equal '("web-search") (plist-get fm :tools)))))

(ert-deftest project-agent-test-frontmatter-empty-key ()
  "A key with no value and no following list items yields nil."
  (let ((fm
         (project-agent--parse-frontmatter
          "---\nschedule:\nname: foo\n---\n")))
    (should-not (plist-get fm :schedule))
    (should (equal "foo" (plist-get fm :name)))))

(ert-deftest project-agent-test-frontmatter-no-markers ()
  "Content without frontmatter delimiters returns nil."
  (should-not
   (project-agent--parse-frontmatter "Just plain text.\n")))

(ert-deftest project-agent-test-frontmatter-whitespace-trimmed ()
  "Leading and trailing whitespace is trimmed from scalar values."
  (let ((fm
         (project-agent--parse-frontmatter
          "---\nname:   padded value   \n---\n")))
    (should (equal "padded value" (plist-get fm :name)))))

;;; ── Skill body ──────────────────────────────────────────────────────────────

(ert-deftest project-agent-test-skill-body-strips-frontmatter ()
  "Everything after the closing --- is returned verbatim as the prompt body."
  (should
   (equal
    "Run the tests.\n"
    (project-agent--skill-body
     "---\nname: foo\n---\nRun the tests.\n"))))

(ert-deftest project-agent-test-skill-body-multiline ()
  "Multi-line prompt bodies are returned in full."
  (should
   (equal
    "Line one.\nLine two.\n"
    (project-agent--skill-body
     "---\nname: bar\n---\nLine one.\nLine two.\n"))))

(ert-deftest project-agent-test-skill-body-no-frontmatter ()
  "Content with no frontmatter is returned unchanged."
  (should
   (equal "bare text" (project-agent--skill-body "bare text"))))

;;; ── Cron field matcher ──────────────────────────────────────────────────────

(ert-deftest project-agent-test-cron-wildcard ()
  "`*' matches any value."
  (should (project-agent--cron-matches "*" 0))
  (should (project-agent--cron-matches "*" 31))
  (should (project-agent--cron-matches "*" 59)))

(ert-deftest project-agent-test-cron-step ()
  "`*/N' matches only multiples of N."
  (should (project-agent--cron-matches "*/15" 0))
  (should (project-agent--cron-matches "*/15" 15))
  (should (project-agent--cron-matches "*/15" 45))
  (should-not (project-agent--cron-matches "*/15" 1))
  (should-not (project-agent--cron-matches "*/15" 14)))

(ert-deftest project-agent-test-cron-literal ()
  "A literal number matches exactly that value."
  (should (project-agent--cron-matches "9" 9))
  (should-not (project-agent--cron-matches "9" 8))
  (should-not (project-agent--cron-matches "9" 10)))

(ert-deftest project-agent-test-cron-range ()
  "`A-B' matches values from A to B inclusive."
  (should (project-agent--cron-matches "1-5" 1))
  (should (project-agent--cron-matches "1-5" 3))
  (should (project-agent--cron-matches "1-5" 5))
  (should-not (project-agent--cron-matches "1-5" 0))
  (should-not (project-agent--cron-matches "1-5" 6)))

(ert-deftest project-agent-test-cron-list ()
  "Comma-separated list matches any listed value, nothing else."
  (should (project-agent--cron-matches "1,3,5" 1))
  (should (project-agent--cron-matches "1,3,5" 3))
  (should (project-agent--cron-matches "1,3,5" 5))
  (should-not (project-agent--cron-matches "1,3,5" 2))
  (should-not (project-agent--cron-matches "1,3,5" 4)))

(ert-deftest project-agent-test-cron-unknown ()
  "An unrecognised field expression returns nil."
  (should-not (project-agent--cron-matches "bad" 5))
  (should-not (project-agent--cron-matches "" 0)))

;;; ── Cron next ───────────────────────────────────────────────────────────────
;;
;; Reference: 2026-07-06 is a Monday (DOW=1 in cron convention, 1=Monday).

(ert-deftest project-agent-test-cron-next-same-day ()
  "One minute before the scheduled time: next fires on the same day."
  (should
   (equal
    "2026-07-06 09:00"
    (project-agent-test--fmt
     (project-agent--cron-next
      "0 9 * * 1"
      (project-agent-test--from "2026-07-06T08:59:00Z"))))))

(ert-deftest project-agent-test-cron-next-next-week ()
  "One minute after the scheduled time: next fires seven days later."
  (should
   (equal
    "2026-07-13 09:00"
    (project-agent-test--fmt
     (project-agent--cron-next
      "0 9 * * 1"
      (project-agent-test--from "2026-07-06T09:01:00Z"))))))

(ert-deftest project-agent-test-cron-next-step-minutes ()
  "`*/5 * * * *' fires on the next 5-minute boundary."
  (should
   (equal
    "2026-07-06 09:05"
    (project-agent-test--fmt
     (project-agent--cron-next
      "*/5 * * * *"
      (project-agent-test--from "2026-07-06T09:01:00Z"))))))

(ert-deftest project-agent-test-cron-next-daily ()
  "`0 9 * * *' fires the next day when today's slot is past."
  (should
   (equal
    "2026-07-07 09:00"
    (project-agent-test--fmt
     (project-agent--cron-next
      "0 9 * * *"
      (project-agent-test--from "2026-07-06T09:01:00Z"))))))

(ert-deftest project-agent-test-cron-next-invalid ()
  "A malformed expression (wrong field count) returns nil."
  (should-not (project-agent--cron-next "not valid"))
  (should-not (project-agent--cron-next "0 9 * *")))

;;; ── Cron prev ───────────────────────────────────────────────────────────────

(ert-deftest project-agent-test-cron-prev-same-day ()
  "One minute after the scheduled time: prev is that same-day slot."
  (should
   (equal
    "2026-07-06 09:00"
    (project-agent-test--fmt
     (project-agent--cron-prev
      "0 9 * * 1"
      (project-agent-test--from "2026-07-06T09:01:00Z"))))))

(ert-deftest project-agent-test-cron-prev-previous-week ()
  "One minute before the scheduled time: prev is last week's slot."
  (should
   (equal
    "2026-06-29 09:00"
    (project-agent-test--fmt
     (project-agent--cron-prev
      "0 9 * * 1"
      (project-agent-test--from "2026-07-06T08:59:00Z"))))))

(ert-deftest project-agent-test-cron-prev-invalid ()
  "A malformed expression returns nil."
  (should-not (project-agent--cron-prev "not valid")))

;;; ── Docs manifest ───────────────────────────────────────────────────────────

(ert-deftest project-agent-test-docs-manifest-round-trip ()
  "Writing and reading back the manifest preserves all entries."
  (project-agent-test--with-project
   (let ((entries
          '((:path "docs/arch.md" :purpose "System architecture")
            (:path "docs/api.md" :purpose "API reference"))))
     (project-agent--write-docs-manifest entries root)
     (let ((back (project-agent--read-docs-manifest root)))
       (should (= 2 (length back)))
       (should (equal "docs/arch.md" (plist-get (nth 0 back) :path)))
       (should
        (equal
         "System architecture" (plist-get (nth 0 back) :purpose)))
       (should (equal "docs/api.md" (plist-get (nth 1 back) :path)))
       (should
        (equal "API reference" (plist-get (nth 1 back) :purpose)))))))

(ert-deftest project-agent-test-docs-manifest-empty-list ()
  "An empty list round-trips correctly."
  (project-agent-test--with-project
   (project-agent--write-docs-manifest '() root)
   (should (equal '() (project-agent--read-docs-manifest root)))))

(ert-deftest project-agent-test-docs-manifest-absent ()
  "Reading a missing manifest returns nil without error."
  (project-agent-test--with-project
   (should-not (project-agent--read-docs-manifest root))))

;;; ── AGENTS.md sync ──────────────────────────────────────────────────────────

(ert-deftest project-agent-test-sync-creates-block ()
  "Sync appends the docs block to an AGENTS.md that has no markers."
  (project-agent-test--with-project
   (let ((agents-md (expand-file-name "AGENTS.md" root)))
     (with-temp-file agents-md
       (insert "# My Project\n\nSome instructions.\n"))
     (project-agent--write-docs-manifest
      '((:path "README.md" :purpose "Overview")) root)
     (project-agent-sync root)
     (let ((c
            (with-temp-buffer
              (insert-file-contents agents-md)
              (buffer-string))))
       (should (string-match-p "<!-- agent:docs:start -->" c))
       (should (string-match-p "<!-- agent:docs:end -->" c))
       (should (string-match-p "README.md" c))
       (should (string-match-p "# My Project" c))))))

(ert-deftest project-agent-test-sync-replaces-block ()
  "Sync replaces the old block in-place; content outside the markers is kept."
  (project-agent-test--with-project
   (let ((agents-md (expand-file-name "AGENTS.md" root)))
     (with-temp-file agents-md
       (insert "# My Project\n\n")
       (insert "<!-- agent:docs:start -->\n")
       (insert "## Project Knowledge Base\n\n- [old.md](old.md)\n")
       (insert "<!-- agent:docs:end -->\n")
       (insert "\n## Other Section\n"))
     (project-agent--write-docs-manifest
      '((:path "new.md" :purpose "New doc")) root)
     (project-agent-sync root)
     (let ((c
            (with-temp-buffer
              (insert-file-contents agents-md)
              (buffer-string))))
       (should (string-match-p "new.md" c))
       (should-not (string-match-p "old.md" c))
       (should (string-match-p "# My Project" c))
       (should (string-match-p "## Other Section" c))))))

(ert-deftest project-agent-test-sync-idempotent ()
  "Running sync twice produces the same AGENTS.md."
  (project-agent-test--with-project
   (let ((agents-md (expand-file-name "AGENTS.md" root)))
     (with-temp-file agents-md
       (insert ""))
     (project-agent--write-docs-manifest
      '((:path "x.md" :purpose "X")) root)
     (project-agent-sync root)
     (let ((after-first
            (with-temp-buffer
              (insert-file-contents agents-md)
              (buffer-string))))
       (project-agent-sync root)
       (let ((after-second
              (with-temp-buffer
                (insert-file-contents agents-md)
                (buffer-string))))
         (should (equal after-first after-second)))))))

(ert-deftest project-agent-test-sync-empty-manifest-placeholder ()
  "An empty (or absent) manifest renders the placeholder line."
  (project-agent-test--with-project
   (let ((agents-md (expand-file-name "AGENTS.md" root)))
     (with-temp-file agents-md
       (insert ""))
     (project-agent-sync root)
     (let ((c
            (with-temp-buffer
              (insert-file-contents agents-md)
              (buffer-string))))
       (should
        (string-match-p "_No documents registered yet._" c))))))

;;; ── Run manifests ───────────────────────────────────────────────────────────

(ert-deftest project-agent-test-run-manifest-initial-status ()
  "A freshly-written manifest has status \"running\"."
  (project-agent-test--with-project
   (let* ((run-id "test-uuid-abc123")
          (path
           (project-agent--write-run-manifest
            root "my-skill" run-id 'batch)))
     (let ((data
            (json-parse-string (with-temp-buffer
                                 (insert-file-contents path)
                                 (buffer-string))
                               :object-type 'plist)))
       (should (equal "running" (plist-get data :status)))
       (should (equal "my-skill" (plist-get data :skill)))
       (should (equal "batch" (plist-get data :mode)))
       (should (equal run-id (plist-get data :session_id)))
       (should (plist-get data :started_at))))))

(ert-deftest project-agent-test-run-manifest-update ()
  "Updating a manifest's status to \"finished\" persists correctly."
  (project-agent-test--with-project
   (let* ((path
           (project-agent--write-run-manifest
            root "my-skill" "uuid-1" 'interactive)))
     (project-agent--update-run-manifest path "finished")
     (let ((data
            (json-parse-string (with-temp-buffer
                                 (insert-file-contents path)
                                 (buffer-string))
                               :object-type 'plist)))
       (should (equal "finished" (plist-get data :status)))
       ;; Other fields must survive the update.
       (should (equal "my-skill" (plist-get data :skill)))))))

(ert-deftest project-agent-test-run-manifest-list ()
  "list-run-manifests returns the manifest written by write-run-manifest."
  (project-agent-test--with-project
   (let ((run-id "uuid-list-test"))
     (project-agent--write-run-manifest root "my-skill" run-id 'batch)
     (let* ((sessions (project-agent--list-run-manifests root))
            (entry (car sessions)))
       (should (= 1 (length sessions)))
       (should (equal run-id (car entry)))
       (should (equal "running" (plist-get (cdr entry) :status)))))))

(ert-deftest project-agent-test-run-manifest-sorted-newest-first ()
  "Multiple manifests are returned newest-first by started_at."
  (project-agent-test--with-project
   (make-directory (expand-file-name ".agent/runs/my-skill" root) t)
   (let ((older
          (expand-file-name
           ".agent/runs/my-skill/20260101T090000-aaa.json"
           root))
         (newer
          (expand-file-name
           ".agent/runs/my-skill/20260706T090000-bbb.json"
           root)))
     (with-temp-file older
       (insert
        (json-serialize
         '(:skill
           "my-skill"
           :session_id "aaa"
           :started_at "2026-01-01T09:00:00Z"
           :mode "batch"
           :status "finished"))))
     (with-temp-file newer
       (insert
        (json-serialize
         '(:skill
           "my-skill"
           :session_id "bbb"
           :started_at "2026-07-06T09:00:00Z"
           :mode "batch"
           :status "finished"))))
     (let* ((sessions (project-agent--list-run-manifests root))
            (ids (mapcar #'car sessions)))
       (should (equal '("bbb" "aaa") ids))))))

(ert-deftest project-agent-test-run-manifest-skips-corrupt-json ()
  "A corrupt JSON file is silently skipped; valid entries are still returned."
  (project-agent-test--with-project
   (make-directory (expand-file-name ".agent/runs/my-skill" root) t)
   (let ((bad
          (expand-file-name
           ".agent/runs/my-skill/20260101T000000-bad.json"
           root))
         (good
          (expand-file-name
           ".agent/runs/my-skill/20260706T000000-good.json"
           root)))
     (with-temp-file bad
       (insert "{not valid json"))
     (with-temp-file good
       (insert
        (json-serialize
         '(:skill
           "my-skill"
           :session_id "good"
           :started_at "2026-07-06T00:00:00Z"
           :mode "batch"
           :status "running"))))
     (let ((sessions (project-agent--list-run-manifests root)))
       (should (= 1 (length sessions)))
       (should (equal "good" (caar sessions)))))))

(provide 'project-agent-test)
;;; project-agent-test.el ends here
