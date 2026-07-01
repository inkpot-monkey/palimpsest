;;; project-agent.el --- Agent workspace management for project.el -*- lexical-binding: t; -*-

;; Author: inkpotmonkey
;; Keywords: project, ai, convenience
;; Package-Requires: ((emacs "29.1") (transient "0.5"))

;;; Commentary:

;; Brings Claude Projects / Cowork capabilities to Emacs on top of the
;; built-in project.el.  Agent-agnostic: the backend protocol is four
;; cl-defgenerics; wire up a concrete backend (e.g. project-agent-claude-code)
;; and set `project-agent-backend'.
;;
;; Entry point: `project-agent-menu' (C-c a), also in project-switch-commands.
;;
;; Directory layout under each project root:
;;
;;   AGENTS.md                    -- persistent instructions (cross-tool standard)
;;   .agent/
;;     docs-manifest.json         -- knowledge base registry
;;     outputs.json               -- artifact registry (path/title/timestamp)
;;     docs/                      -- knowledge base files
;;     skills/<name>/SKILL.md     -- skill definitions
;;     runs/<name>/<ts>-<id>.json -- run manifests

;;; Code:

(require 'cl-lib)
(require 'cl-generic)
(require 'project)
(require 'transient)
(require 'multisession)

(defvar-local project-agent--run-id nil
  "Run UUID stamped in each agent session buffer so it can be found by ID.")

;;; ── Backend protocol ──────────────────────────────────────────────────────

(cl-defgeneric project-agent-launch
    (backend session-id root prompt &key mode tools)
  "Start a new agent session.
BACKEND    — active backend struct.
SESSION-ID — pre-generated run UUID (passed to the backend for context), or nil.
ROOT       — absolute project root path.
PROMPT     — initial prompt string, or nil for plain interactive use.
MODE       — \\='interactive (buffer displayed) or \\='batch (hidden buffer).
TOOLS      — list of MCP server name strings.
Returns the session buffer.")

(cl-defgeneric project-agent-resume (backend session-id root)
  "Reopen or attach to an existing session by SESSION-ID.
Falls back to opening a new session in ROOT if no live buffer is found.
Returns the buffer.")

(cl-defgeneric project-agent-list-sessions (backend root)
  "Return alist of (SESSION-ID . PLIST) for the given ROOT.
PLIST keys: :skill :mode :status :started-at.")

(cl-defgeneric project-agent-session-status (backend session-id)
  "Return current status of SESSION-ID: \\='running or \\='finished.")

;;; ── Active backend ──────────────────────────────────────────────────────────

(defvar project-agent-backend nil
  "The active backend struct.  Must be set before any session command is run.
Example (for the built-in claude-code backend):
  (require \\='project-agent-claude-code)
  (setq project-agent-backend (project-agent-make-claude-code-backend))")

(defun project-agent--require-backend ()
  "Error with a helpful message when no backend is configured."
  (unless project-agent-backend
    (user-error
     "project-agent: no backend configured.  Set `project-agent-backend', e.g.:
  (require 'project-agent-claude-code)
  (setq project-agent-backend (project-agent-make-claude-code-backend))")))

;;; ── Internal helpers ────────────────────────────────────────────────────────

(defun project-agent--root ()
  "Return current project root, erroring if none."
  (project-root (project-current t)))

(defun project-agent--agent-dir (&optional root)
  "Return .agent/ path under ROOT (defaults to current project)."
  (expand-file-name ".agent" (or root (project-agent--root))))

(defun project-agent--uuid ()
  "Generate a UUID using the kernel PRNG."
  (string-trim
   (with-temp-buffer
     (insert-file-contents "/proc/sys/kernel/random/uuid")
     (buffer-string))))

(defun project-agent--iso8601 (&optional time)
  "Format TIME (defaults to now) as ISO8601 UTC."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ"
                      (or time (current-time))
                      t))

;;; ── Knowledge base (issue 02) ───────────────────────────────────────────────

(defconst project-agent--docs-start "<!-- agent:docs:start -->")
(defconst project-agent--docs-end "<!-- agent:docs:end -->")

(defun project-agent--docs-manifest-path (&optional root)
  (expand-file-name ".agent/docs-manifest.json"
                    (or root (project-agent--root))))

(defun project-agent--read-docs-manifest (&optional root)
  "Return docs manifest as a list of plists.  Returns nil if absent."
  (let ((path (project-agent--docs-manifest-path root)))
    (when (file-exists-p path)
      (json-parse-string (with-temp-buffer
                           (insert-file-contents path)
                           (buffer-string))
                         :object-type 'plist
                         :array-type 'list))))

(defun project-agent--write-docs-manifest (entries &optional root)
  "Write ENTRIES (list of plists) to the docs manifest."
  (let ((path (project-agent--docs-manifest-path root)))
    (make-directory (file-name-directory path) t)
    (with-temp-file path
      (insert
       (json-serialize (vconcat entries) :false-object :false)))))

;;;###autoload
(defun project-agent-sync (&optional root)
  "Regenerate the agent:docs block in AGENTS.md for ROOT."
  (interactive)
  (let* ((root (or root (project-agent--root)))
         (entries (project-agent--read-docs-manifest root))
         (agents-md (expand-file-name "AGENTS.md" root))
         (block
          (concat
           project-agent--docs-start
           "\n"
           "## Project Knowledge Base\n\n"
           (if entries
               (mapconcat (lambda (e)
                            (format "- [%s](%s)"
                                    (or (plist-get e :purpose)
                                        (file-name-nondirectory
                                         (plist-get e :path)))
                                    (plist-get e :path)))
                          entries
                          "\n")
             "_No documents registered yet._")
           "\n"
           project-agent--docs-end)))
    (with-current-buffer (find-file-noselect agents-md)
      (save-excursion
        (goto-char (point-min))
        (if (search-forward project-agent--docs-start nil t)
            ;; Replace existing block: from start of start-marker to end of
            ;; end-marker (search-forward leaves point after the string).
            (let ((region-start (match-beginning 0)))
              (when (search-forward project-agent--docs-end nil t)
                (delete-region region-start (match-end 0))
                (goto-char region-start)
                (insert block)))
          ;; No markers yet: append block at end of file.
          (goto-char (point-max))
          (unless (bolp)
            (insert "\n"))
          (insert "\n" block "\n")))
      (save-buffer))))

;;;###autoload
(defun project-agent-add-doc (path purpose)
  "Register PATH with PURPOSE in the project knowledge base."
  (interactive (let* ((root (project-agent--root))
                      (p (read-file-name "Doc file: " root nil t))
                      (pu (read-string "One-line purpose: ")))
                 (list (file-relative-name p root) pu)))
  (let* ((root (project-agent--root))
         (entries (or (project-agent--read-docs-manifest root) '()))
         (entry (list :path path :purpose purpose)))
    (unless (cl-find
             path
             entries
             :key (lambda (e) (plist-get e :path))
             :test #'equal)
      (project-agent--write-docs-manifest (append
                                           entries (list entry))
                                          root))
    (project-agent-sync root)
    (message "project-agent: added %s to knowledge base" path)))

;;;###autoload
(defun project-agent-remove-doc (path)
  "Remove PATH from the project knowledge base."
  (interactive (let* ((root (project-agent--root))
                      (entries
                       (project-agent--read-docs-manifest root))
                      (paths
                       (mapcar
                        (lambda (e) (plist-get e :path)) entries)))
                 (list (completing-read "Remove doc: " paths nil t))))
  (let* ((root (project-agent--root))
         (entries (project-agent--read-docs-manifest root))
         (filtered
          (cl-remove
           path
           entries
           :key (lambda (e) (plist-get e :path))
           :test #'equal)))
    (project-agent--write-docs-manifest filtered root)
    (project-agent-sync root)
    (message "project-agent: removed %s from knowledge base" path)))

;;; ── Artifact registry (issue 07) ────────────────────────────────────────────

(defun project-agent--artifacts-path (&optional root)
  "Return the .agent/outputs.json path for ROOT."
  (expand-file-name ".agent/outputs.json"
                    (or root (project-agent--root))))

(defun project-agent--read-artifacts (&optional root)
  "Return artifacts as a list of plists (:path :title :timestamp), or nil."
  (let ((path (project-agent--artifacts-path root)))
    (when (file-exists-p path)
      (json-parse-string (with-temp-buffer
                           (insert-file-contents path)
                           (buffer-string))
                         :object-type 'plist
                         :array-type 'list))))

(defun project-agent--write-artifacts (entries &optional root)
  "Write ENTRIES (list of plists) to .agent/outputs.json."
  (let ((path (project-agent--artifacts-path root)))
    (make-directory (file-name-directory path) t)
    (with-temp-file path
      (insert
       (json-serialize (vconcat entries) :false-object :false)))))

;;;###autoload
(defun project-agent-register-artifact (path title)
  "Register PATH as a project artifact with TITLE in .agent/outputs.json."
  (interactive (let* ((root (project-agent--root))
                      (p
                       (read-file-name "Artifact file: " root nil t))
                      (ti (read-string "Title: ")))
                 (list (file-relative-name p root) ti)))
  (let* ((root (project-agent--root))
         (entries (or (project-agent--read-artifacts root) '()))
         (entry
          (list
           :path path
           :title title
           :timestamp (project-agent--iso8601)))
         (updated
          (cons
           entry
           (cl-remove
            path
            entries
            :key (lambda (e) (plist-get e :path))
            :test #'equal))))
    (project-agent--write-artifacts updated root)
    (message "project-agent: registered artifact %s" path)))

;;; ── Skill management (issue 04) ─────────────────────────────────────────────

(defun project-agent--parse-frontmatter (content)
  "Parse YAML frontmatter from CONTENT.  Returns plist or nil.
Handles scalar values, quoted strings, and simple list-of-scalars."
  (when (string-match "\\`---\n\\(\\(?:.*\n\\)*?\\)---\n" content)
    (let ((yaml (match-string 1 content))
          (result '())
          (current-key nil))
      (dolist (line (split-string yaml "\n"))
        (cond
         ;; List item under the current key
         ((and current-key (string-match "\\`  - \\(.*\\)" line))
          (let ((val (string-trim (match-string 1 line))))
            (setq result
                  (plist-put
                   result current-key
                   (append
                    (plist-get result current-key) (list val))))))
         ;; Scalar key: value pair
         ((string-match "\\`\\([a-z_-]+\\): *\\(.*\\)\\'" line)
          (let ((key (intern (concat ":" (match-string 1 line))))
                (val (string-trim (match-string 2 line))))
            (setq current-key key)
            ;; Strip surrounding quotes
            (when (string-match "\\`\"\\(.*\\)\"\\'" val)
              (setq val (match-string 1 val)))
            (setq result
                  (plist-put
                   result key
                   (if (string-empty-p val)
                       nil
                     val)))))
         ;; Blank line or unrecognised: end any open list
         (t
          (unless (string-empty-p (string-trim line))
            (setq current-key nil)))))
      result)))

(defun project-agent--skill-body (content)
  "Return the prompt body from CONTENT (everything after the closing ---)."
  (if (string-match "\\`---\n\\(?:.*\n\\)*?---\n" content)
      (substring content (match-end 0))
    content))

(defun project-agent--skills-dir (&optional root)
  "Return the .agent/skills/ directory path."
  (expand-file-name ".agent/skills" (or root (project-agent--root))))

(defun project-agent--list-skills (&optional root)
  "Return list of parsed skill plists for ROOT.
Each plist includes :name :mode :schedule :tools :prompt :dir :slug."
  (let ((skills-dir (project-agent--skills-dir root)))
    (when (file-directory-p skills-dir)
      (cl-mapcan
       (lambda (dir)
         (let ((skill-file (expand-file-name "SKILL.md" dir)))
           (when (file-exists-p skill-file)
             (let* ((content
                     (with-temp-buffer
                       (insert-file-contents skill-file)
                       (buffer-string)))
                    (fm (project-agent--parse-frontmatter content))
                    (body (project-agent--skill-body content)))
               (list
                (append
                 fm
                 (list
                  :prompt body
                  :dir dir
                  :slug (file-name-nondirectory dir))))))))
       (directory-files skills-dir t "\\`[^.]")))))

;;; ── Run manifests (issues 04, 05) ───────────────────────────────────────────

(defun project-agent--run-manifest-path (root skill-slug ts run-id)
  "Return the path for a run manifest."
  (expand-file-name (format "%s-%s.json" ts run-id)
                    (expand-file-name skill-slug
                                      (expand-file-name ".agent/runs"
                                                        root))))

(defun project-agent--write-run-manifest (root skill-slug run-id mode)
  "Write an initial \\='running\\=' run manifest; return its path."
  (let* ((ts (format-time-string "%Y%m%dT%H%M%S" (current-time) t))
         (path
          (project-agent--run-manifest-path
           root skill-slug ts run-id)))
    (make-directory (file-name-directory path) t)
    (with-temp-file path
      (insert
       (json-serialize
        `(:skill
          ,skill-slug
          :session_id ,run-id
          :started_at ,(project-agent--iso8601)
          :mode ,(symbol-name mode)
          :status "running"))))
    path))

(defun project-agent--update-run-manifest (path status)
  "Update the :status field in the manifest at PATH."
  (when (file-exists-p path)
    (let* ((data
            (json-parse-string (with-temp-buffer
                                 (insert-file-contents path)
                                 (buffer-string))
                               :object-type 'plist))
           (updated (plist-put data :status status)))
      (with-temp-file path
        (insert (json-serialize updated))))))

(defun project-agent--list-run-manifests (&optional root)
  "Return alist of (run-id . plist) from .agent/runs/, newest first."
  (let ((runs-dir
         (expand-file-name ".agent/runs"
                           (or root (project-agent--root))))
        result)
    (when (file-directory-p runs-dir)
      (dolist (skill-dir (directory-files runs-dir t "\\`[^.]"))
        (when (file-directory-p skill-dir)
          (dolist (json-file
                   (directory-files skill-dir t "\\.json\\'"))
            (condition-case nil
                (let* ((data
                        (json-parse-string (with-temp-buffer
                                             (insert-file-contents
                                              json-file)
                                             (buffer-string))
                                           :object-type 'plist))
                       (id (plist-get data :session_id)))
                  (push (cons id data) result))
              (error
               nil))))))
    (sort result
          (lambda (a b)
            (string>
             (or (plist-get (cdr a) :started_at) "")
             (or (plist-get (cdr b) :started_at) ""))))))

;;; ── Skill runner (issue 04) ─────────────────────────────────────────────────

(defun project-agent--pick-skill (&optional root)
  "Completing-read over skills in ROOT.  Returns the skill plist."
  (let* ((skills (project-agent--list-skills root))
         (_
          (unless skills
            (user-error
             "project-agent: no skills found in .agent/skills/")))
         (names
          (mapcar
           (lambda (s)
             (or (plist-get s :name) (plist-get s :slug)))
           skills))
         (chosen (completing-read "Skill: " names nil t)))
    (cl-find
     chosen
     skills
     :key (lambda (s) (or (plist-get s :name) (plist-get s :slug)))
     :test #'equal)))

(defun project-agent--launch-skill (skill mode)
  "Launch SKILL in MODE, write a run manifest, wire a finish sentinel."
  (project-agent--require-backend)
  (let* ((root (project-agent--root))
         (slug (plist-get skill :slug))
         (prompt (plist-get skill :prompt))
         (tools (plist-get skill :tools))
         (run-id (project-agent--uuid))
         (manifest-path
          (project-agent--write-run-manifest root slug run-id mode))
         (buf
          (project-agent-launch
           project-agent-backend
           run-id
           root
           prompt
           :mode mode
           :tools tools)))
    ;; Stamp the run-id on the buffer so resume can find it later.
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq project-agent--run-id run-id))
      ;; Wire a sentinel to mark the manifest finished when the process exits.
      (when-let ((proc (get-buffer-process buf)))
        (let ((prev (process-sentinel proc)))
          (set-process-sentinel
           proc
           (lambda (p event)
             (when (or (string-match-p "finished" event)
                       (string-match-p "exited" event))
               (project-agent--update-run-manifest
                manifest-path "finished"))
             (when prev
               (funcall prev p event)))))))
    buf))

;;;###autoload
(defun project-agent-run-skill ()
  "Pick a skill and launch it interactively in the current project."
  (interactive)
  (project-agent--launch-skill
   (project-agent--pick-skill) 'interactive))

;;;###autoload
(defun project-agent-run-skill-batch ()
  "Pick a skill and launch it as a hidden batch session."
  (interactive)
  (let ((buf
         (project-agent--launch-skill
          (project-agent--pick-skill) 'batch)))
    (message "project-agent: batch session started — %s"
             (buffer-name buf))))

;;; ── Session browser (issue 05) ──────────────────────────────────────────────

(defun project-agent--session-label (_id plist)
  "Format a completing-read label for a session PLIST."
  (format "[%s] %s · %s"
          (or (plist-get plist :skill) "interactive")
          (let ((ts (or (plist-get plist :started_at) "?")))
            (substring ts 0 (min 16 (length ts))))
          (or (plist-get plist :status) "?")))

;;;###autoload
(defun project-agent-sessions ()
  "Completing-read over sessions for the current project; open or resume."
  (interactive)
  (project-agent--require-backend)
  (let* ((root (project-agent--root))
         (sessions
          (project-agent-list-sessions project-agent-backend root))
         (_
          (unless sessions
            (user-error "project-agent: no sessions found")))
         (table
          (mapcar
           (lambda (s)
             (cons (project-agent--session-label (car s) (cdr s)) s))
           sessions))
         (chosen
          (completing-read "Session: " (mapcar #'car table) nil t))
         (entry (cdr (assoc chosen table)))
         (id (car entry)))
    (project-agent-resume project-agent-backend id root)))

;; Tabulated-list session browser

(defvar-local project-agent--list-root nil)

(defvar project-agent-list-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'project-agent-list-open)
    (define-key m (kbd "d") #'project-agent-list-delete)
    (define-key m (kbd "g") #'project-agent-list-refresh)
    m))

(define-derived-mode
 project-agent-list-mode
 tabulated-list-mode
 "Agent-Sessions"
 "Major mode for browsing project-agent session manifests."
 (setq tabulated-list-format
       [("Skill" 20 t) ("Mode" 8 t) ("Status" 10 t) ("Started" 20 t)])
 (tabulated-list-init-header))

(defun project-agent--list-entries (root)
  "Build `tabulated-list-entries' for ROOT."
  (mapcar
   (lambda (s)
     (let* ((id (car s))
            (p (cdr s))
            (ts (or (plist-get p :started_at) "")))
       (list
        id
        (vector
         (or (plist-get p :skill) "interactive")
         (or (plist-get p :mode) "?")
         (or (plist-get p :status) "?")
         (substring ts 0 (min 19 (length ts)))))))
   (project-agent-list-sessions project-agent-backend root)))

;;;###autoload
(defun project-agent-list ()
  "Open the tabulated session browser for the current project."
  (interactive)
  (project-agent--require-backend)
  (let* ((root (project-agent--root))
         (buf
          (get-buffer-create
           (format "*Agent Sessions: %s*"
                   (file-name-nondirectory
                    (directory-file-name root))))))
    (with-current-buffer buf
      (project-agent-list-mode)
      (setq project-agent--list-root root)
      (setq tabulated-list-entries (project-agent--list-entries root))
      (tabulated-list-print))
    (pop-to-buffer buf)))

(defun project-agent-list-open ()
  "Open or resume the session on the current tabulated-list line."
  (interactive)
  (when-let ((id (tabulated-list-get-id)))
    (project-agent-resume
     project-agent-backend id project-agent--list-root)))

(defun project-agent-list-delete ()
  "Delete the run manifest for the session on the current line."
  (interactive)
  (when-let ((id (tabulated-list-get-id)))
    (when (yes-or-no-p (format "Delete manifest for %s? " id))
      (let ((runs-dir
             (expand-file-name ".agent/runs"
                               project-agent--list-root)))
        (dolist (skill-dir (directory-files runs-dir t "\\`[^.]"))
          (dolist (f (directory-files skill-dir t (regexp-quote id)))
            (delete-file f))))
      (project-agent-list-refresh))))

(defun project-agent-list-refresh ()
  "Refresh the session list."
  (interactive)
  (setq tabulated-list-entries
        (project-agent--list-entries project-agent--list-root))
  (tabulated-list-print t))

;;; ── Scheduling (issue 06) ───────────────────────────────────────────────────

(defun project-agent--cron-matches (field value)
  "Return t if cron FIELD matches integer VALUE."
  (cond
   ((equal field "*")
    t)
   ((string-match "\\`\\*/\\([0-9]+\\)\\'" field)
    (zerop (mod value (string-to-number (match-string 1 field)))))
   ((string-match "\\`[0-9]+\\'" field)
    (= value (string-to-number field)))
   ((string-match "\\`\\([0-9]+\\)-\\([0-9]+\\)\\'" field)
    (and (>= value (string-to-number (match-string 1 field)))
         (<= value (string-to-number (match-string 2 field)))))
   ((string-match "," field)
    (member
     value (mapcar #'string-to-number (split-string field ","))))
   (t
    nil)))

(defun project-agent--cron-next (expr &optional from)
  "Return the next fire time for cron EXPR after FROM (defaults to now).
Scans minute-by-minute for up to one week; returns nil if no match found."
  (let* ((from (or from (current-time)))
         (candidate (time-add from 60))
         (parts (split-string (string-trim expr) " ")))
    (when (= (length parts) 5)
      (cl-destructuring-bind
       (min-f hour-f dom-f month-f dow-f) parts
       (catch 'found
         (dotimes (_ (* 7 24 60))
           (let* ((d (decode-time candidate))
                  (min (nth 1 d))
                  (hour (nth 2 d))
                  (dom (nth 3 d))
                  (month (nth 4 d))
                  (dow (nth 6 d)))
             (when (and (project-agent--cron-matches min-f min)
                        (project-agent--cron-matches hour-f hour)
                        (project-agent--cron-matches dom-f dom)
                        (project-agent--cron-matches month-f month)
                        (project-agent--cron-matches dow-f dow))
               (throw 'found candidate)))
           (setq candidate (time-add candidate 60)))
         nil)))))

(defun project-agent--cron-prev (expr &optional from)
  "Return the most recent past fire time for EXPR before FROM.
Scans backward minute-by-minute for up to one week."
  (let* ((from (or from (current-time)))
         (candidate (time-subtract from 60))
         (parts (split-string (string-trim expr) " ")))
    (when (= (length parts) 5)
      (cl-destructuring-bind
       (min-f hour-f dom-f month-f dow-f) parts
       (catch 'found
         (dotimes (_ (* 7 24 60))
           (let* ((d (decode-time candidate))
                  (min (nth 1 d))
                  (hour (nth 2 d))
                  (dom (nth 3 d))
                  (month (nth 4 d))
                  (dow (nth 6 d)))
             (when (and (project-agent--cron-matches min-f min)
                        (project-agent--cron-matches hour-f hour)
                        (project-agent--cron-matches dom-f dom)
                        (project-agent--cron-matches month-f month)
                        (project-agent--cron-matches dow-f dow))
               (throw 'found candidate)))
           (setq candidate (time-subtract candidate 60)))
         nil)))))

(define-multisession-variable
 project-agent--last-runs
 nil
 "Alist of (\"<root>/<skill>\" . ISO8601-timestamp) for scheduled skills.")

(defun project-agent--schedule-key (root slug)
  (concat (directory-file-name root) "/" slug))

(defun project-agent--parse-timestamp (ts)
  "Parse an ISO8601 UTC timestamp like \"2026-07-06T09:00:00Z\" to a time value."
  (when
      (string-match
       (concat
        "\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)"
        "T\\([0-9]\\{2\\}\\):\\([0-9]\\{2\\}\\):\\([0-9]\\{2\\}\\)Z")
       ts)
    (encode-time
     (list
      (string-to-number (match-string 6 ts))
      (string-to-number (match-string 5 ts))
      (string-to-number (match-string 4 ts))
      (string-to-number (match-string 3 ts))
      (string-to-number (match-string 2 ts))
      (string-to-number (match-string 1 ts))
      nil
      nil
      0))))

(defun project-agent--last-run-time (root slug)
  "Return the last-run Emacs time value for ROOT/SLUG, or nil."
  (when-let ((ts
              (alist-get (project-agent--schedule-key root slug)
                         (multisession-value project-agent--last-runs)
                         nil
                         nil
                         #'equal)))
    (project-agent--parse-timestamp ts)))

(defun project-agent--record-run (root slug)
  "Persist now as the last-run timestamp for ROOT/SLUG."
  (let ((key (project-agent--schedule-key root slug))
        (alist (multisession-value project-agent--last-runs)))
    (setf (multisession-value project-agent--last-runs)
          (cons
           (cons key (project-agent--iso8601))
           (cl-remove key alist :key #'car :test #'equal)))))

(defun project-agent--schedule-skill (root skill)
  "Register a run-at-time timer for the next occurrence of SKILL in ROOT."
  (let* ((slug (plist-get skill :slug))
         (expr (plist-get skill :schedule))
         (next (project-agent--cron-next expr)))
    (when next
      (run-at-time next nil #'project-agent--fire-scheduled
                   root
                   skill))))

(defun project-agent--fire-scheduled (root skill)
  "Run SKILL as batch, record it, and schedule the subsequent occurrence."
  (let ((slug (plist-get skill :slug))
        (default-directory root))
    (condition-case err
        (progn
          (project-agent--launch-skill skill 'batch)
          (project-agent--record-run root slug))
      (error
       (message "project-agent: scheduled run failed for %s: %s"
                slug
                (error-message-string err)))))
  (project-agent--schedule-skill root skill))

(defun project-agent--load-schedules ()
  "On startup: scan known projects, catch up missed runs, set timers."
  (dolist (root (project-known-project-roots))
    (dolist (skill (project-agent--list-skills root))
      (when-let ((expr (plist-get skill :schedule)))
        (let* ((slug (plist-get skill :slug))
               (last-run (project-agent--last-run-time root slug))
               (prev (project-agent--cron-prev expr)))
          ;; Single catch-up: run now if the last scheduled tick was missed.
          (when (and prev
                     (or (null last-run) (time-less-p last-run prev)))
            (project-agent--fire-scheduled root skill))
          ;; Arm the next future occurrence.
          (project-agent--schedule-skill root skill))))))

(add-hook 'emacs-startup-hook #'project-agent--load-schedules)

;;; ── Home buffer (issues 08, 09) ─────────────────────────────────────────────

(defvar-local project-agent-home--root nil
  "Project root stored in the home buffer.")

(defvar project-agent-home-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "n") #'project-agent-home--next-item)
    (define-key m (kbd "p") #'project-agent-home--prev-item)
    (define-key m (kbd "g") #'project-agent-home--refresh)
    (define-key m (kbd "q") #'bury-buffer)
    (define-key m (kbd "RET") #'project-agent-home--open-item)
    m)
  "Keymap for `project-agent-home-mode'.")

(define-derived-mode
 project-agent-home-mode
 special-mode
 "Agent Home"
 "Major mode for the project-agent project home screen."
 :group 'project-agent)

(defun project-agent-home--buffer-name (root)
  "Return the home buffer name for ROOT."
  (format "*agent-home:%s*"
          (abbreviate-file-name (directory-file-name root))))

(defun project-agent-home--render (root)
  "Render the home screen for ROOT into the current buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (setq project-agent-home--root root)
    (insert
     (propertize (format "Project: %s\n" (abbreviate-file-name root))
                 'face 'bold))
    (insert (make-string 50 ?═) "\n\n")
    ;; Artifacts
    (insert (propertize "Artifacts\n" 'face '(:inherit bold)))
    (let ((artifacts (project-agent--read-artifacts root)))
      (if artifacts
          (dolist (a artifacts)
            (let* ((ts (or (plist-get a :timestamp) ""))
                   (ts10 (substring ts 0 (min 10 (length ts))))
                   (line
                    (format "  %-38s  %s  %s\n"
                            (plist-get a :path)
                            ts10
                            (or (plist-get a :title) ""))))
              (insert
               (propertize line
                           'project-agent-item
                           (list
                            :type 'artifact
                            :path (plist-get a :path)
                            :root root)))))
        (insert "  (none)\n")))
    (insert "\n")
    ;; Sessions
    (insert (propertize "Sessions\n" 'face '(:inherit bold)))
    (let ((runs
           (seq-take (project-agent--list-run-manifests root) 10)))
      (if runs
          (dolist (s runs)
            (let* ((id (car s))
                   (p (cdr s))
                   (ts (or (plist-get p :started_at) ""))
                   (status (or (plist-get p :status) "?"))
                   (ind
                    (if (equal status "running")
                        "◉"
                      "○"))
                   (line
                    (format "  %s  %-16s  %-20s  %s\n"
                            ind
                            (substring ts 0 (min 16 (length ts)))
                            (or (plist-get p :skill) "interactive")
                            (if (equal status "running")
                                "(running)"
                              ""))))
              (insert
               (propertize line
                           'project-agent-item
                           (list :type 'session :id id :root root)))))
        (insert "  (none)\n")))
    (insert "\n")
    ;; Scheduled
    (insert (propertize "Scheduled\n" 'face '(:inherit bold)))
    (let ((skills (project-agent--list-skills root))
          (any nil))
      (dolist (skill skills)
        (when-let ((expr (plist-get skill :schedule)))
          (setq any t)
          (let* ((slug (plist-get skill :slug))
                 (next (project-agent--cron-next expr))
                 (nstr
                  (if next
                      (format-time-string "%Y-%m-%d %H:%M" next)
                    "?"))
                 (line
                  (format "  %-20s  %-20s  next: %s\n"
                          (or (plist-get skill :name) slug)
                          expr
                          nstr)))
            (insert
             (propertize line
                         'project-agent-item
                         (list
                          :type 'scheduled
                          :slug slug
                          :root root))))))
      (unless any
        (insert "  (none)\n")))))

(defun project-agent-home--next-item ()
  "Move to the next item line."
  (interactive)
  (forward-line 1)
  (while (and (not (eobp))
              (null (get-text-property (point) 'project-agent-item)))
    (forward-line 1)))

(defun project-agent-home--prev-item ()
  "Move to the previous item line."
  (interactive)
  (forward-line -1)
  (while (and (not (bobp))
              (null (get-text-property (point) 'project-agent-item)))
    (forward-line -1)))

(defun project-agent-home--refresh ()
  "Re-render the home buffer."
  (interactive)
  (when project-agent-home--root
    (project-agent-home--render project-agent-home--root)))

(defun project-agent-home--open-item ()
  "Open or resume the item at point."
  (interactive)
  (when-let ((item (get-text-property (point) 'project-agent-item)))
    (pcase (plist-get item :type)
      ('artifact
       (find-file-other-window
        (expand-file-name (plist-get item :path)
                          (plist-get item :root))))
      ('session
       (project-agent--require-backend)
       (project-agent-resume
        project-agent-backend
        (plist-get item :id)
        (plist-get item :root)))
      ('scheduled
       (project-agent-home--open-scheduled
        (plist-get item :slug) (plist-get item :root))))))

(defun project-agent--runs-for-slug (root slug)
  "Return run manifests for SLUG in ROOT, newest first."
  (cl-remove-if-not
   (lambda (s)
     (equal (plist-get (cdr s) :skill) slug))
   (project-agent--list-run-manifests root)))

(defun project-agent-home--open-scheduled (slug root)
  "Resume the latest run for SLUG and show a history footer window."
  (project-agent--require-backend)
  (let ((runs (project-agent--runs-for-slug root slug)))
    (if (null runs)
        (message "project-agent: no runs found for %s" slug)
      (project-agent-resume project-agent-backend (caar runs) root)
      (project-agent-home--show-history-footer slug root runs))))

(defun project-agent-home--show-history-footer (slug root runs)
  "Split an 8-line footer window below showing RUNS for SLUG."
  (let* ((name (format "*agent-history:%s*" slug))
         (buf (get-buffer-create name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert
         (propertize (format "Runs: %s  (%s)\n"
                             slug
                             (abbreviate-file-name root))
                     'face 'bold))
        (insert (make-string 50 ?─) "\n")
        (dolist (run runs)
          (let* ((p (cdr run))
                 (ts (or (plist-get p :started_at) ""))
                 (status (or (plist-get p :status) "?"))
                 (ind
                  (if (equal status "running")
                      "◉"
                    "○")))
            (insert
             (format "  %s  %s  %s\n"
                     ind
                     (substring ts 0 (min 16 (length ts)))
                     status)))))
      (special-mode)
      (local-set-key (kbd "q") #'delete-window))
    (set-window-buffer (split-window-below -8) buf)))

;;;###autoload
(defun project-agent-home (&optional root)
  "Open the project-agent home screen for the current project."
  (interactive)
  (let* ((root (or root (project-agent--root)))
         (buf
          (get-buffer-create (project-agent-home--buffer-name root))))
    (with-current-buffer buf
      (unless (derived-mode-p 'project-agent-home-mode)
        (project-agent-home-mode))
      (project-agent-home--render root))
    (switch-to-buffer buf)))

(defun project-agent--after-switch-project (&rest _)
  "Auto-open home buffer when the new project has a .agent/ workspace."
  (when-let ((proj
              (ignore-errors
                (project-current))))
    (let ((root (project-root proj)))
      (when (file-directory-p (expand-file-name ".agent" root))
        (project-agent-home root)))))

(advice-add
 'project-switch-project
 :after #'project-agent--after-switch-project)

;;; ── Built-in skills (issue 03) ───────────────────────────────────────────────

(defvar project-agent-builtin-skills-dir
  (expand-file-name "skills"
                    (file-name-directory
                     (or load-file-name
                         buffer-file-name
                         (locate-library "project-agent"))))
  "Directory of built-in skills shipped with the package.
Resolves to the `skills/' directory alongside the installed .el file.")

(defun project-agent--read-builtin-skill (name)
  "Return (FRONTMATTER-PLIST . PROMPT-BODY) for built-in skill NAME."
  (let ((path
         (expand-file-name (concat name "/SKILL.md")
                           project-agent-builtin-skills-dir)))
    (unless (file-exists-p path)
      (user-error "project-agent: built-in skill %s not found at %s"
                  name
                  path))
    (let* ((content
            (with-temp-buffer
              (insert-file-contents path)
              (buffer-string)))
           (fm (project-agent--parse-frontmatter content))
           (body (project-agent--skill-body content)))
      (cons fm body))))

;;; ── Commands ────────────────────────────────────────────────────────────────

;;;###autoload
(defun project-agent-new-session ()
  "Open an interactive agent session in the current project root."
  (interactive)
  (project-agent--require-backend)
  (project-agent-launch
   project-agent-backend
   nil
   (project-agent--root)
   nil
   :mode 'interactive))

;;;###autoload
(defun project-agent-edit-instructions ()
  "Open AGENTS.md at the current project root, creating it if absent."
  (interactive)
  (find-file (expand-file-name "AGENTS.md" (project-agent--root))))

;;;###autoload
(defun project-agent-init ()
  "Scaffold .agent/ workspace and open an init grilling session."
  (interactive)
  (project-agent--require-backend)
  (let* ((root (project-agent--root))
         (agent-dir (project-agent--agent-dir root)))
    (when (file-exists-p agent-dir)
      (user-error "project-agent: .agent/ already exists in %s" root))
    (dolist (subdir '("docs" "skills" "runs"))
      (make-directory (expand-file-name subdir agent-dir) t))
    (let* ((skill-data
            (project-agent--read-builtin-skill "init-project"))
           (prompt (cdr skill-data))
           (buf
            (project-agent-launch
             project-agent-backend
             nil
             root
             prompt
             :mode 'interactive)))
      ;; On session end, sync the knowledge base in case the init skill
      ;; registered any docs during its run.
      (when (buffer-live-p buf)
        (when-let ((proc (get-buffer-process buf)))
          (let ((prev (process-sentinel proc)))
            (set-process-sentinel
             proc
             (lambda (p event)
               (when (or (string-match-p "finished" event)
                         (string-match-p "exited" event))
                 (condition-case nil
                     (project-agent-sync root)
                   (error
                    nil)))
               (when prev
                 (funcall prev p event))))))))
    (message "project-agent: workspace initialised at %s" agent-dir)))

;;; ── Transient menu ──────────────────────────────────────────────────────────

;;;###autoload (autoload 'project-agent-menu "project-agent" nil t)
(transient-define-prefix
 project-agent-menu
 ()
 "Agent workspace commands for the current project."
 ["Sessions" ("n" "New session" project-agent-new-session)
  ("s"
   "Browse sessions"
   project-agent-sessions)
  ("l" "Session list" project-agent-list)]
 ["Skills"
  ("k" "Run skill" project-agent-run-skill)
  ("K" "Run skill (batch)" project-agent-run-skill-batch)]
 ["Knowledge base"
  ("d a" "Add doc" project-agent-add-doc)
  ("d r" "Remove doc" project-agent-remove-doc)
  ("d s" "Sync AGENTS.md" project-agent-sync)]
 ["Artifacts" ("a"
   "Register artifact"
   project-agent-register-artifact)]
 ["Project"
  ("h" "Home" project-agent-home)
  ("i" "Init workspace" project-agent-init)
  ("e" "Edit instructions" project-agent-edit-instructions)])

(provide 'project-agent)
;;; project-agent.el ends here
