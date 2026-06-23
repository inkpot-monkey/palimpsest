;;; consult-omni-launch.el --- Popup-frame app launcher over consult-omni -*- lexical-binding: t; -*-

;; Author: inkpotmonkey
;; Keywords: convenience, frames

;;; Commentary:

;; A dmenu-style launcher built on consult-omni, meant to be invoked in a
;; dedicated frame (e.g. an `emacs-launcher' frame spawned by a hotkey):
;; `consult-omni-launch' focuses the current frame, runs the multi-source search,
;; and deletes the frame on selection, quit, or error — so the frame behaves like
;; a one-shot launcher rather than a lingering Emacs window.
;;
;; The set of sources searched (and any callback overrides) stay with your
;; consult-omni configuration; this module only owns the frame lifecycle.

;;; Code:

(declare-function consult-omni-multi "consult-omni")

;;;###autoload
(defun consult-omni-launch ()
  "Run `consult-omni-multi' in the current frame, deleting it on exit.
Intended for a dedicated launcher frame: the frame is focused, the search
runs, and the frame is removed on completion, quit, or error."
  (interactive)
  (select-frame-set-input-focus (selected-frame))
  (condition-case nil
      (progn
        (consult-omni-multi nil "Run: ")
        ;; Small delay so the action is initiated before the frame is deleted.
        (run-at-time "0.1 sec" nil #'delete-frame))
    (quit (delete-frame))
    (error (message "Launcher error occurred")
           (delete-frame))))

(provide 'consult-omni-launch)
;;; consult-omni-launch.el ends here
