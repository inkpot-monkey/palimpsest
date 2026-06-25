;;; just-complete.el --- A completing-read interface for Justfile recipes -*- lexical-binding: t; -*-

;; Author: Inkpotmonkey
;; Version: 1.2
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; This package provides a completing-read interface for running recipes from a Justfile.
;; It parses the output of `just --list` and shows arguments and comments in Marginalia.
;; It features:
;; 1. Caching of candidates per project based on Justfile modification time.
;; 2. Smart argument prompting (parsing arguments and prompting for them individually).
;; 3. Embark integration for viewing recipe source.

;;; Code:

(require 'project)
(require 'compile)
(require 'subr-x)

(defgroup just-complete nil
  "Completing-read interface for Just."
  :group 'external)

(defcustom just-complete-executable "just"
  "The just executable to use."
  :type 'string
  :group 'just-complete)

(defface just-complete-args
  '((t :inherit font-lock-variable-name-face))
  "Face for just recipe arguments in completion annotations."
  :group 'just-complete)

(defface just-complete-comment
  '((t :inherit marginalia-documentation))
  "Face for just recipe comments in completion annotations."
  :group 'just-complete)

(defvar just-complete-history nil
  "History for just recipe selection.")

(defvar just-complete-argument-history nil
  "History for just recipe arguments.")

(defvar just-complete--cache (make-hash-table :test 'equal)
  "Cache for just recipes.
Key is project root, value is (mod-time . candidates).")

(defvar marginalia-annotator-registry nil)
(defvar embark-keymap-alist nil)

(defun just-recipe-annotator (cand)
  "Annotate a just recipe candidate CAND for Marginalia."
  (let ((args (get-text-property 0 'just-args cand))
        (comment (get-text-property 0 'just-comment cand)))
    (concat
     (when (and args (not (string-empty-p args)))
       (propertize (concat " " args) 'face 'just-complete-args))
     (when (and comment (not (string-empty-p comment)))
       (concat
        "  " (propertize comment 'face 'just-complete-comment))))))

(defun just-complete--parse-args (args-str)
  "Parse arguments string from just output.
Returns a list of lists: ((name default is-variadic) ...)."
  (when (and args-str (not (string-empty-p args-str)))
    (let ((args (split-string args-str "[ \t]+" t))
          (parsed nil))
      (dolist (arg args)
        (let ((is-variadic (string-prefix-p "*" arg))
              (name arg)
              (default nil))
          (when is-variadic
            (setq name (substring arg 1)))
          ;; Check for default value (e.g. name='value' or name="value" or name=value)
          (if (string-match "\\([^=]+\\)=\\(.*\\)" name)
              (let ((n (match-string 1 name))
                    (d (match-string 2 name)))
                (setq name n)
                (setq default d)
                ;; Strip quotes
                (when (string-match "^['\"]\\(.*\\)['\"]$" default)
                  (setq default (match-string 1 default)))))
          (push (list name default is-variadic) parsed)))
      (nreverse parsed))))

(defun just-complete--get-candidates ()
  "Get candidates for completion, using cache if valid."
  (let* ((project (project-current))
         (root
          (if project
              (project-root project)
            default-directory))
         (justfile (expand-file-name "Justfile" root))
         (cache-val (gethash root just-complete--cache))
         (mod-time
          (when (file-exists-p justfile)
            (file-attribute-modification-time
             (file-attributes justfile))))
         (candidates nil))
    (if (and cache-val (equal (car cache-val) mod-time))
        (setq candidates (cdr cache-val))
      ;; Cache invalid or missing, parse file
      (with-temp-buffer
        (condition-case nil
            (let ((exit-code
                   (call-process just-complete-executable
                                 nil
                                 t
                                 nil
                                 "--list"))
                  (output (buffer-string)))
              (if (/= exit-code 0)
                  (message
                   "Error: `just --list` failed with exit code %d."
                   exit-code)
                (let ((lines (split-string output "\n" t)))
                  (dolist (line lines)
                    (when
                        (string-match
                         "^[ \t]+\\([^ ]+\\)\\([^#]*\\)[ \t]*\\(# \\(.*\\)\\)?$"
                         line)
                      (let* ((recipe (match-string 1 line))
                             (args-raw (match-string 2 line))
                             (comment (match-string 4 line))
                             (args (string-trim (or args-raw "")))
                             (cand
                              (propertize recipe
                                          'just-args
                                          args
                                          'just-comment
                                          (or comment ""))))
                        (push cand candidates))))
                  (setq candidates (nreverse candidates))
                  ;; Update cache
                  (puthash
                   root
                   (cons mod-time candidates)
                   just-complete--cache))))
          (file-missing
           (message
            "Error: `just` executable not found in exec-path.")))))
    candidates))

(defun just-run+ ()
  "Select and run a `just` recipe for the current project."
  (interactive)
  (let ((candidates (just-complete--get-candidates)))
    (if (not candidates)
        (message "No just recipes found")
      (let* ((choice
              (completing-read "Just recipe: "
                               (lambda (string pred action)
                                 (if (eq action 'metadata)
                                     '(metadata
                                       (category . just-recipe))
                                   (complete-with-action
                                    action candidates string pred)))
                               nil t nil 'just-complete-history))
             (selected-cand (car (member choice candidates)))
             (args-str
              (when selected-cand
                (get-text-property 0 'just-args selected-cand)))
             (parsed-args (just-complete--parse-args args-str))
             (project (project-current))
             (proj-name
              (if project
                  (file-name-nondirectory
                   (directory-file-name (project-root project)))
                (file-name-nondirectory
                 (directory-file-name default-directory))))
             (buf-name (format "*just [%s] %s*" proj-name choice)))
        (when (and choice (not (string-empty-p choice)))
          (let ((compilation-buffer-name-function
                 (lambda (_) buf-name)))
            (if parsed-args
                ;; Smart argument prompting
                (let ((collected-args nil))
                  (dolist (arg parsed-args)
                    (let* ((name (nth 0 arg))
                           (default (nth 1 arg))
                           (is-variadic (nth 2 arg))
                           (prompt
                            (if is-variadic
                                (format "Argument %s (variadic): "
                                        name)
                              (format "Argument %s: " name)))
                           (val
                            (read-string
                             prompt
                             default
                             'just-complete-argument-history)))
                      (when (and val (not (string-empty-p val)))
                        (push val collected-args))))
                  (setq collected-args (nreverse collected-args))
                  (let ((cmd
                         (concat
                          "just " choice " "
                          (mapconcat #'identity collected-args " "))))
                    (compile (string-trim cmd))))
              ;; No arguments needed
              (compile (format "just %s" choice)))))))))

;;; Embark Integration

(defvar just-complete-recipe-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "v") #'just-complete-view-source)
    map)
  "Keymap for embark actions on just recipes.")

(defun just-complete-view-source (cand)
  "View source of just recipe CAND."
  (interactive "s")
  (let* ((project (project-current))
         (root
          (if project
              (project-root project)
            default-directory))
         (justfile (expand-file-name "Justfile" root)))
    (if (file-exists-p justfile)
        (progn
          (find-file justfile)
          (goto-char (point-min))
          (if (re-search-forward (concat "^" cand) nil t)
              (goto-char (match-beginning 0))
            (message "Recipe not found in Justfile")))
      (message "Justfile not found"))))

;; Register with Marginalia
(with-eval-after-load 'marginalia
  (if (boundp 'marginalia-annotators)
      (add-to-list
       'marginalia-annotators
       '(just-recipe just-recipe-annotator none))
    (add-to-list
     'marginalia-annotator-registry
     '(just-recipe just-recipe-annotator none))))

;; Register with Embark
(with-eval-after-load 'embark
  (add-to-list
   'embark-keymap-alist '(just-recipe . just-complete-recipe-map)))

(provide 'just-complete)

;;; just-complete.el ends here
