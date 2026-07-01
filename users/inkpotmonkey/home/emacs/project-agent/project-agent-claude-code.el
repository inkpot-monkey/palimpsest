;;; project-agent-claude-code.el --- Claude-code backend for project-agent -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "29.1") (project-agent "0.1") (claude-code "0.4"))

;;; Commentary:

;; Wires project-agent to the claude-code/ghostel terminal backend.
;;
;; Load after both packages are available and set the backend:
;;
;;   (require 'project-agent-claude-code)
;;   (setq project-agent-backend (project-agent-make-claude-code-backend))
;;
;; Interactive sessions open a ghostel buffer in the current window.
;; Batch sessions are hidden (display-buffer-no-window); the initial
;; prompt is injected 3 seconds after the process starts.

;;; Code:

(require 'cl-lib)
(require 'cl-generic)
(require 'project-agent)
(require 'claude-code)

;;; ── Backend struct ──────────────────────────────────────────────────────────

(cl-defstruct
 (project-agent-claude-code
  (:constructor project-agent-claude-code--make)))

(defun project-agent-make-claude-code-backend ()
  "Return a new claude-code backend instance."
  (project-agent-claude-code--make))

;;; ── Helpers ─────────────────────────────────────────────────────────────────

(defun project-agent-claude-code--live-buffers ()
  "Return currently live *claude:…* buffers."
  (cl-remove-if-not
   (lambda (b)
     (string-prefix-p "*claude:" (buffer-name b)))
   (buffer-list)))

(defun project-agent-claude-code--find-by-run-id (run-id)
  "Return the live buffer whose `project-agent--run-id' equals RUN-ID, or nil."
  (cl-find-if
   (lambda (b)
     (and (buffer-live-p b)
          (equal
           (buffer-local-value 'project-agent--run-id b) run-id)))
   (buffer-list)))

;;; ── Backend methods ─────────────────────────────────────────────────────────

(cl-defmethod project-agent-launch
    ((backend project-agent-claude-code)
     _id
     root
     prompt
     &key
     mode
     _tools)
  "Launch claude-code in ROOT.
Interactive: display immediately.
Batch: hidden buffer; PROMPT injected via process-send-string after 3 s."
  (ignore backend)
  (let ((default-directory root))
    (if (eq mode 'batch)
        (let* ((before (project-agent-claude-code--live-buffers))
               (_
                (let ((display-buffer-alist
                       (cons
                        '("\\`\\*claude:" (display-buffer-no-window))
                        display-buffer-alist)))
                  (claude-code)))
               (buf
                (car
                 (cl-set-difference
                  (project-agent-claude-code--live-buffers)
                  before
                  :test #'eq))))
          (when (and buf prompt)
            (run-with-timer 3.0 nil
                            (lambda (b p)
                              (when (buffer-live-p b)
                                (when-let ((proc
                                            (get-buffer-process b)))
                                  (process-send-string
                                   proc (concat p "\n")))))
                            buf prompt))
          (or buf (current-buffer)))
      ;; Interactive: display immediately, then return the buffer.
      (claude-code)
      (current-buffer))))

(cl-defmethod project-agent-resume
    ((backend project-agent-claude-code) session-id root)
  "Switch to the live buffer for SESSION-ID, or open a new session in ROOT."
  (ignore backend)
  (let ((live (project-agent-claude-code--find-by-run-id session-id)))
    (if live
        (progn
          (pop-to-buffer live)
          live)
      (let ((default-directory root))
        (claude-code)
        (current-buffer)))))

(cl-defmethod project-agent-list-sessions
    ((backend project-agent-claude-code) root)
  "Return run manifests from .agent/runs/ as (id . plist) alist."
  (ignore backend)
  (project-agent--list-run-manifests root))

(cl-defmethod project-agent-session-status
    ((backend project-agent-claude-code) session-id)
  "Return \\='running if a live buffer holds SESSION-ID, else \\='finished."
  (if (project-agent-claude-code--find-by-run-id session-id)
      'running
    'finished))

(provide 'project-agent-claude-code)
;;; project-agent-claude-code.el ends here
