;;; -*- lexical-binding: t; -*-

(require 'auth-source)
(require 'compile)

;;;###autoload
(defconst pritunl--buffer-name "*pritunl*"
  "The name of the buffer used for Pritunl process output.")

(defconst pritunl--ready-regexp "connection: Resolved remotes"
  "The regex string indicating the service is ready for connections.")

;;;###autoload
(defun pritunl-start-service ()
  "Start the `pritunl-client-service` as root using TRAMP.
Prompts for the sudo password automatically via the minibuffer.
The process output is sent to the buffer *pritunl*."
  (interactive)
  (let ((compilation-scroll-output t)
	(compilation-buffer-name-function
	 (lambda (_) pritunl--buffer-name))
	(default-directory "/sudo::/")
	(cmd (executable-find "pritunl-client-service"))
	(display-buffer-alist 
         '(("\\*pritunl\\*" display-buffer-no-window (allow-no-window . t)))))
    (envrc--clear (buffer-name))
    (compile cmd)))

(defun pritunl--check-ready-hook ()
  "Hook run on compilation output. Checks if service is ready."
  ;; Scan the buffer for the ready string
  (save-excursion
    (goto-char (point-min)) 
    (when (re-search-forward pritunl--ready-regexp nil t)
      (remove-hook 'compilation-filter-hook #'pritunl--check-ready-hook t)
      (pritunl-connect-client))))

(defun pritunl--get-credentials ()
  "Fetch Pritunl credentials from `auth-source'.
The entry should be of the form:
  machine pritunl login <id> password <password>
Returns a cons cell `(ID . PASSWORD)' or nil if not found."
  (let ((entry (car (auth-source-search :host "pritunl" :max 1))))
    (when entry
      (let* ((user (plist-get entry :user))
             (secret-val (plist-get entry :secret))
             (password (if (functionp secret-val)
                           (funcall secret-val)
                         secret-val)))
        (cons user password)))))

(defun pritunl-connect-client ()
  "Connect the Pritunl client using credentials."
  (if-let* ((creds (pritunl--get-credentials))
            (id (car creds))
            (password (cdr creds)))
      (progn
	(start-process "pritunl-client"
                       nil
                       "pritunl-client"
                       "start" id
                       "--password" password)
	(message (format "Pritunl connected with client ID: %s" id)))
    (message "Error: No 'machine pritunl' entry found in auth-source.")))

;;;###autoload
(defun pritunl-connect ()
  "Start service and wait for specific output before connecting."
  (interactive)
  (message "Starting Pritunl service")
  (let ((buffer (pritunl-start-service)))
    (with-current-buffer buffer
      (remove-hook 'compilation-filter-hook #'pritunl--check-ready-hook t)
      (add-hook 'compilation-filter-hook #'pritunl--check-ready-hook nil t))))

;;;###autoload
(defun pritunl-disconnect ()
  "Kills the `pritunl' process that was started by `pritunl-connect'."
  (interactive)
  (message "Disconnecting Pritunl...")

  (let ((service-msg)
	(proc (get-buffer-process pritunl--buffer-name)))
    (if (and proc (process-live-p proc))
        (progn
          (kill-process proc)
          (setq service-msg "service stopped"))
      (setq service-msg "service not found"))

    (when-let ((buf (get-buffer pritunl--buffer-name)))
      (kill-buffer buf))

    (message "Pritunl: %s." service-msg)))

(provide 'pritunl-connect)

;;; pritunl-connect.el ends here
