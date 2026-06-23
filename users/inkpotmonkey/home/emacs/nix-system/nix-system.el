;;; nix-system.el --- Drive this host's NixOS + network from Emacs -*- lexical-binding: t; -*-

;; Author: inkpotmonkey
;; Keywords: tools, processes, convenience

;;; Commentary:

;; System-control commands for a NixOS workstation, in one place:
;;
;;   * `nix-rebuild-system+' / `nix-update-system-flake+' run `nixos-rebuild
;;     switch' and `nix flake update' against `nix-system-flake-directory', each
;;     in its own named compilation buffer (rebuild goes via TRAMP sudo).  A
;;     prefix arg adds `--show-trace' to the rebuild.
;;   * `nix-system-network-transient' is a Transient menu over NetworkManager
;;     (via enwc + nmcli): it shows the current IPv4 address live in its heading,
;;     scans, restarts NetworkManager, and forgets a chosen connection.
;;
;; Bind whichever commands you use; all are autoloaded.

;;; Code:

(require 'transient)
(require 'subr-x)

(declare-function envrc--clear "envrc")
(declare-function enwc "enwc")
(declare-function enwc-scan "enwc")

(defgroup nix-system nil
  "Drive NixOS and NetworkManager from Emacs."
  :group 'tools
  :prefix "nix-system-")

(defcustom nix-system-flake-directory "~/code/nixos"
  "Directory holding the system flake used for rebuilds and updates."
  :type 'directory)

;;;###autoload
(defun nix-rebuild-system+ (&optional host)
  "Build NixOS HOST (default: function `system-name') from the system flake.
With a prefix argument, pass `--show-trace'.  Runs via TRAMP sudo in a
buffer named after the command."
  (interactive)
  (let ((compilation-scroll-output t)
        (default-directory (concat "/sudo::" (expand-file-name nix-system-flake-directory)))
        (compilation-buffer-name-function
         (lambda (_) (concat "*" (symbol-name this-command) "*")))
        (show-trace (if current-prefix-arg "--show-trace" "")))
    (envrc--clear (buffer-name))
    (compile
     (format "nixos-rebuild switch %s --flake .#%s" show-trace (or host (system-name))))))

;;;###autoload
(defun nix-update-system-flake+ (&optional flake-path)
  "Update a flake at FLAKE-PATH (default: `nix-system-flake-directory')."
  (interactive)
  (let ((default-directory nix-system-flake-directory)
        (compilation-buffer-name-function
         (lambda (_) (concat "*" (symbol-name this-command) "*"))))
    (envrc--clear (buffer-name))
    (compile (concat "nix flake update --flake " (or flake-path default-directory)))))

(defun nix-system--ipv4-address ()
  "Return the current IPv4 address of the active wifi interface, or \"Disconnected\"."
  (let ((addr (string-trim
               (shell-command-to-string
                "nmcli -t -f IP4.ADDRESS dev show $(nmcli -t -f DEVICE,TYPE dev status | grep wifi | cut -d: -f1) | cut -d: -f2 | head -n1"))))
    (if (string-empty-p addr) "Disconnected" addr)))

(defun nix-system-delete-connection ()
  "Delete a NetworkManager connection chosen by name (via nmcli)."
  (interactive)
  (let* ((connections (split-string
                       (shell-command-to-string "nmcli -t -f UUID,NAME con show") "\n" t))
         (candidates (mapcar (lambda (line)
                               (let ((parts (split-string line ":" t)))
                                 (cons (cadr parts) (car parts))))
                             connections))
         (selection (completing-read "Delete connection: " candidates)))
    (shell-command (format "nmcli con delete %s" (cdr (assoc selection candidates))))
    (message "Deleted connection: %s" selection)))

;;;###autoload (autoload 'nix-system-network-transient "nix-system" nil t)
(transient-define-prefix nix-system-network-transient ()
  "NetworkManager control menu."
  [:description
   (lambda () (format "Network Manager (IP: %s)" (nix-system--ipv4-address)))
   ["Actions"
    ("e" "ENWC Interface" enwc)
    ("s" "Scan Networks" enwc-scan)
    ("r" "Restart NetworkManager"
     (lambda () (interactive)
       (start-process "pkexec" nil "pkexec" "systemctl" "restart" "NetworkManager")))
    ("f" "Forget Connection" nix-system-delete-connection)
    ("q" "Quit" transient-quit-one)]])

(provide 'nix-system)
;;; nix-system.el ends here
