;;; ement-glue.el --- Convenience entry points for Ement Matrix -*- lexical-binding: t; -*-

;; Author: inkpotmonkey
;; Keywords: comm, convenience

;;; Commentary:

;; One-keystroke Matrix on top of Ement: connect to a fixed homeserver/user
;; without retyping the MXID (reusing a saved session when there is one), jump
;; straight to the room list (connecting first if needed), and a `ement-glue-map'
;; prefix map gathering the Ement commands used day to day.
;;
;; Set `ement-glue-user-id' to your MXID and bind `ement-glue-map' where you like
;; (e.g. \"C-c m\").  The autoloaded commands pull in Ement on first use, so this
;; adds nothing to startup.

;;; Code:

(require 'subr-x)

(defvar ement-sessions)
(declare-function ement-connect "ement")
(declare-function ement-disconnect "ement")
(declare-function ement-list-rooms "ement")

(defgroup ement-glue nil
  "Convenience wrappers around Ement."
  :group 'comm
  :prefix "ement-glue-")

(defcustom ement-glue-user-id "@inkpotmonkey:matrix.palebluebytes.space"
  "Matrix user ID to connect as."
  :type 'string)

;;;###autoload
(defun ement-glue-connect ()
  "Connect to Matrix as `ement-glue-user-id', reusing a saved session if any."
  (interactive)
  (require 'ement)
  (if-let ((session (cdr (assoc ement-glue-user-id ement-sessions))))
      (ement-connect :session session)
    (ement-connect :user-id ement-glue-user-id)))

;;;###autoload
(defun ement-glue-list ()
  "Show the Ement room list, connecting first if needed."
  (interactive)
  (require 'ement)
  (unless ement-sessions
    (if (y-or-n-p "Not connected to Matrix.  Connect now? ")
        (ement-glue-connect)
      (user-error "Not connected to Matrix")))
  (ement-list-rooms))

;;;###autoload
(defun ement-glue-disconnect ()
  "Disconnect every active Ement session."
  (interactive)
  (require 'ement)
  (ement-disconnect (mapcar #'cdr ement-sessions)))

;;;###autoload (autoload 'ement-glue-map "ement-glue" nil t 'keymap)
(define-prefix-command 'ement-glue-map)
(define-key ement-glue-map (kbd "c") #'ement-glue-connect)
(define-key ement-glue-map (kbd "m") #'ement-glue-connect)
(define-key ement-glue-map (kbd "d") #'ement-glue-disconnect)
(define-key ement-glue-map (kbd "l") #'ement-glue-list)
(define-key ement-glue-map (kbd "v") #'ement-view-room)
(define-key ement-glue-map (kbd "s") #'ement-room-send-image)
(define-key ement-glue-map (kbd "f") #'ement-room-send-file)
(define-key ement-glue-map (kbd "i") #'ement-invite-user)
(define-key ement-glue-map (kbd "S") #'ement-directory-search)

(provide 'ement-glue)
;;; ement-glue.el ends here
