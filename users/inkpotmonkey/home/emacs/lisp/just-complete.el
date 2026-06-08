;;; just-complete.el --- A completing-read interface for Justfile recipes -*- lexical-binding: t; -*-

;; Author: Inkpotmonkey
;; Version: 1.0
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; This package provides a completing-read interface for running recipes from a Justfile.
;; It parses the output of `just --list` and shows arguments and comments in Marginalia.

;;; Code:

(require 'project)
(require 'compile)
(require 'subr-x)

(defvar just-recipes-alist nil
  "Alist of parsed just recipes.
Each element is (name . (args comment)).")

(defun just-recipe-annotator (cand)
  "Annotate a just recipe candidate CAND for Marginalia."
  (let ((data (cdr (assoc cand just-recipes-alist))))
    (when data
      (let ((args (car data))
            (comment (cadr data)))
        (concat (when (and args (not (string-empty-p args)))
                  (propertize (concat " " args) 'face 'font-lock-variable-name-face))
                (when (and comment (not (string-empty-p comment)))
                  (concat "  " (propertize comment 'face 'marginalia-documentation))))))))

(defun just-run+ ()
  "Select and run a `just` recipe for the current project."
  (interactive)
  (let ((output-buffer (generate-new-buffer " *just-output*")))
    (condition-case err
        (let ((exit-code (call-process "just" nil output-buffer nil "--list"))
              (output (with-current-buffer output-buffer
                        (buffer-string))))
          (kill-buffer output-buffer)
          (if (/= exit-code 0)
              (message "Error: `just --list` failed with exit code %d." exit-code)
            (let ((lines (split-string output "\n" t)))
              (let ((recipes-alist nil))
                (dolist (line lines)
                  (when (string-match "^    \\([^ ]+\\)\\(.*?\\)[ \t]*\\(# \\(.*\\)\\)?$" line)
                    (let ((recipe (match-string 1 line))
                          (args (string-trim (or (match-string 2 line) "")))
                          (comment (match-string 4 line)))
                      (push (cons recipe (list args (or comment ""))) recipes-alist))))
                (setq recipes-alist (nreverse recipes-alist))
                (setq just-recipes-alist recipes-alist)
                
                (let ((choices (mapcar #'car recipes-alist)))
                  (if (not choices)
                      (message "No just recipes found")
                    (let* ((choice (completing-read
                                    "Just recipe: "
                                    (lambda (string pred action)
                                      (if (eq action 'metadata)
                                          '(metadata (category . just-recipe))
                                        (complete-with-action action choices string pred)))
                                    nil t))
                           (data (cdr (assoc choice recipes-alist)))
                           (args (car data))
                           (project (project-current))
                           (proj-name (if project 
                                          (file-name-nondirectory (directory-file-name (project-root project)))
                                        (file-name-nondirectory (directory-file-name default-directory))))
                           (buf-name (format "*just [%s] %s*" proj-name choice)))
                      (when (and choice (not (string-empty-p choice)))
                        (let ((compilation-buffer-name-function (lambda (_) buf-name)))
                          (if (and args (not (string-empty-p args)))
                              (let ((cmd (read-string "Command: " (format "just %s " choice))))
                                (compile cmd))
                            (compile (format "just %s" choice))))))))))))
      (file-missing
       (kill-buffer output-buffer)
       (message "Error: `just` executable not found in exec-path.")))))

;; Register with Marginalia if it is loaded
(with-eval-after-load 'marginalia
  (add-to-list 'marginalia-annotator-registry
               '(just-recipe just-recipe-annotator none)))

(provide 'just-complete)

;;; just-complete.el ends here
