;;; early-init.el --- Early Init File -*- lexical-binding: t; no-byte-compile: t -*-

(setq gc-cons-threshold most-positive-fixnum)

;; Push to alist is the most performant and correct way in early-init
(push '(menu-bar-lines . 0) default-frame-alist)
(push '(tool-bar-lines . 0) default-frame-alist)
(push '(vertical-scroll-bars) default-frame-alist)
(push '(internal-border-width . 8) default-frame-alist)
(push '(undecorated . t) default-frame-alist)
(push '(fullscreen . maximized) initial-frame-alist)

;; Disable resizing early
(setq frame-inhibit-implied-resize t
      frame-resize-pixelwise t)

;; UI inhibition
(setq inhibit-startup-screen t
      inhibit-startup-message t
      inhibit-startup-echo-area-message user-login-name
      initial-scratch-message nil)

(setq package-native-compile t) 

(when (and (fboundp 'startup-redirect-eln-cache)
           (fboundp 'native-comp-available-p)
           (native-comp-available-p))
  (startup-redirect-eln-cache
   (convert-standard-filename
    (expand-file-name  "var/eln-cache/" user-emacs-directory))))

;;; early-init.el ends here
