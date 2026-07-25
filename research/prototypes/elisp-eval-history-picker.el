;;; elisp-eval-history-picker.el --- PROTOTYPE for palimpsest #78 -*- lexical-binding: t; -*-

;; THROWAWAY PROTOTYPE.  Not wired into the emacs build; nothing under
;; research/prototypes/ is loaded by home-manager.  Delete once #78 is decided.
;;
;; Purpose: give a *concrete thing to react to* for the consult front-end of the
;; elisp-eval history store (map #73).  It hardcodes a fake store and stands up
;; the picker so you can feel: marginalia columns, narrowing keys, preview of a
;; multi-line sexp, the Embark action list, and — most importantly — what
;; re-eval *context* should mean.  No capture, no persistence: pure UI.
;;
;; Run in your CONFIGURED Emacs (needs consult + marginalia + embark):
;;   M-x load-file RET research/prototypes/elisp-eval-history-picker.el RET
;;   M-x eehp-pick RET
;; then press `C-M-x'-style narrowing keys shown in the prompt, and `embark-act'.

;;; Code:

(require 'consult)
(require 'marginalia)

;; ---------------------------------------------------------------------------
;; Fake store — the #75/#76/#77 record, one plist per entry.
;; NOTE the `:buffer' field: #75/#76 keep it, but #77's serialization dropped it
;; to (:text :last-eval :count :entry-point :file).  This prototype carries it so
;; we can *feel* buffer-narrowing (see the `b' key) and decide whether it earns
;; its place back in the serialized record.  `*scratch*' entries have :file nil —
;; the case that makes file-only narrowing miss the most common elisp context.
;; ---------------------------------------------------------------------------

(defvar eehp--store
  (let ((now (float-time)))
    (list
     (list
      :text "(chelys-galactica-run)"
      :last-eval (- now 45)
      :count 3
      :entry-point 'last-sexp
      :buffer "init.el"
      :file "~/.config/emacs/init.el")
     (list
      :text "(setq my/debug t)"
      :last-eval (- now 8)
      :count 12
      :entry-point 'expression
      :buffer "*scratch*"
      :file nil)
     (list
      :text "(defun eehp-demo (x)\n  ;; comment kept verbatim — never re-printed\n  (when (> x 0)\n    (message \"pos %s\" x)))"
      :last-eval (- now 600)
      :count 5
      :entry-point 'region
      :buffer "elisp-eval-history.el"
      :file "~/.config/emacs/elisp-eval-history.el")
     (list
      :text "(message \"hi %s\" user-login-name)"
      :last-eval (- now 172800)
      :count 1
      :entry-point 'expression
      :buffer "*scratch*"
      :file nil)
     (list
      :text "(require 'consult)"
      :last-eval (- now 3600)
      :count 8
      :entry-point 'last-sexp
      :buffer "init.el"
      :file "~/.config/emacs/init.el")
     (list
      :text "(cl-loop for x in '(1 2 3) collect (* x x))"
      :last-eval (- now 90000)
      :count 2
      :entry-point 'region
      :buffer "*ielm*-experiments.el"
      :file "~/scratch/experiments.el")))
  "Fake in-memory store of eval records for the prototype.")

;; ---------------------------------------------------------------------------
;; Rendering helpers
;; ---------------------------------------------------------------------------

(defvar eehp--entry-point-glyph
  '((last-sexp . "·e") ; C-x C-e / C-j
    (expression . ":") ; M-:
    (region . "▚r")) ; C-M-x / region blob
  "Short glyph per entry-point for the marginalia column.")

(defun eehp--ago (secs)
  "Human 'N ago' for SECS in the past (float-time delta)."
  (let ((d (- (float-time) secs)))
    (cond
     ((< d 60)
      (format "%ds" (round d)))
     ((< d 3600)
      (format "%dm" (round (/ d 60))))
     ((< d 86400)
      (format "%dh" (round (/ d 3600))))
     (t
      (format "%dd" (round (/ d 86400)))))))

(defun eehp--oneline (text width)
  "Collapse TEXT to one display line, ellipsized to WIDTH cols.
The candidate string keeps the full multi-line TEXT (so preview and re-eval
see it verbatim); only the DISPLAY is flattened."
  (let* ((flat
          (replace-regexp-in-string "[ \t]*\n[ \t]*" " ⏎ " text)))
    (if (<= (string-width flat) width)
        flat
      (concat
       (truncate-string-to-width flat (max 1 (1- width))) "…"))))

(defun eehp--candidates ()
  "Build display candidates carrying their record as a text property."
  (let ((width (max 24 (min 64 (- (frame-width) 44)))))
    (mapcar
     (lambda (rec)
       (propertize (eehp--oneline (plist-get rec :text) width)
                   'eehp-record
                   rec))
     ;; recency default sort (mirrors chelys-galactica-sort-by 'recency)
     (sort (copy-sequence eehp--store)
           (lambda (a b)
             (> (plist-get a :last-eval)
                (plist-get b :last-eval)))))))

(defun eehp--annotate (cand)
  "Marginalia annotation: entry-point · count · buffer/file · ago."
  (when-let* ((rec (get-text-property 0 'eehp-record cand)))
    (let* ((ep (plist-get rec :entry-point))
           (buf (plist-get rec :buffer))
           (file (plist-get rec :file))
           (origin
            (cond
             (file
              (abbreviate-file-name file))
             (buf
              (concat buf)) ; *scratch* etc — no file
             (t
              ""))))
      (marginalia--fields
       ((or (cdr (assq ep eehp--entry-point-glyph)) "?")
        :width 3
        :face 'marginalia-type)
       ((format "×%d" (plist-get rec :count))
        :width 5
        :face 'marginalia-number)
       (origin :truncate -0.5 :face 'marginalia-file-name)
       ((eehp--ago (plist-get rec :last-eval))
        :width 5
        :face 'marginalia-date)))))

(add-to-list
 'marginalia-annotators '(eehp-record eehp--annotate builtin none))

;; ---------------------------------------------------------------------------
;; Narrowing — DEMONSTRATES BOTH AXES so we can pick:
;;   entry-point:  e/r/l    (expression / region / last-sexp)
;;   origin:       b/f/p    (this buffer name / this file / this project root)
;; The picker prompt shows them; press one, then `DEL' to clear.
;; ---------------------------------------------------------------------------

(defvar eehp--narrow-keys
  '((?e . "expression")
    (?r . "region")
    (?l . "last-sexp")
    (?b . "this-buffer")
    (?f . "this-file")
    (?p . "this-project"))
  "Prototype narrowing keys — entry-point axis + origin axis, side by side.")

(defun eehp--narrow-predicate (cand)
  (let* ((rec (get-text-property 0 'eehp-record cand))
         (ep (plist-get rec :entry-point)))
    (pcase consult--narrow
      (?e (eq ep 'expression))
      (?r (eq ep 'region))
      (?l (eq ep 'last-sexp))
      (?b (equal (plist-get rec :buffer) eehp--pick-buffer))
      (?f
       (and (plist-get rec :file)
            eehp--pick-file
            (file-equal-p (plist-get rec :file) eehp--pick-file)))
      (?p
       (and (plist-get rec :file)
            eehp--pick-project
            (string-prefix-p
             eehp--pick-project
             (expand-file-name (plist-get rec :file)))))
      (_ t))))

(defvar eehp--pick-buffer nil)
(defvar eehp--pick-file nil)
(defvar eehp--pick-project nil)

;; ---------------------------------------------------------------------------
;; Preview — pop the FULL (possibly multi-line) sexp into a lisp buffer as you
;; move.  This is what a single-line command picker (chelys) never needed.
;; ---------------------------------------------------------------------------

(defun eehp--preview ()
  (let ((buf (get-buffer-create "*eehp preview*")))
    (lambda (action cand)
      (pcase action
        ('preview
         (when cand
           (let ((rec (get-text-property 0 'eehp-record cand)))
             (with-current-buffer buf
               (erase-buffer)
               (emacs-lisp-mode)
               (insert (plist-get rec :text)))
             (display-buffer buf
                             '(display-buffer-at-bottom
                               (window-height . 0.3))))))
        ('return
         (when (get-buffer buf)
           (kill-buffer buf)))))))

;; ---------------------------------------------------------------------------
;; The picker
;; ---------------------------------------------------------------------------

(defun eehp--read ()
  (let ((eehp--pick-buffer (buffer-name))
        (eehp--pick-file
         (and buffer-file-name (expand-file-name buffer-file-name)))
        (eehp--pick-project
         (when-let* ((p
                      (and (fboundp 'project-current)
                           (project-current nil))))
           (expand-file-name (project-root p)))))
    (consult--read
     (eehp--candidates)
     :prompt "Eval history: "
     :category 'eehp-record
     :sort nil
     :require-match t
     :state (eehp--preview)
     :preview-key 'any
     :narrow
     (list
      :predicate #'eehp--narrow-predicate
      :keys eehp--narrow-keys))))

;;;###autoload
(defun eehp-pick ()
  "Prototype: pick an eval-history entry (no action; just echoes the record)."
  (interactive)
  (let* ((cand (eehp--read))
         (rec (get-text-property 0 'eehp-record cand)))
    (message "picked %S from buffer=%s file=%s"
             (plist-get rec :entry-point)
             (plist-get rec :buffer)
             (plist-get rec :file))))

;; ---------------------------------------------------------------------------
;; Embark actions — the candidate list to react to.
;; Re-eval is the load-bearing one: it MESSAGES the three context choices so the
;; semantics question is concrete instead of abstract.
;; ---------------------------------------------------------------------------

(defun eehp--rec-at (cand)
  (get-text-property 0 'eehp-record cand))

(defun eehp-reeval (cand)
  "PROTOTYPE re-eval: show the THREE candidate contexts, don't actually eval."
  (interactive "sEntry: ")
  (let* ((rec (eehp--rec-at cand))
         (obuf (plist-get rec :buffer))
         (live (and obuf (get-buffer obuf))))
    (message (concat
              "re-eval %S\n"
              "  A) current buffer   : %s\n"
              "  B) origin buffer    : %s%s\n"
              "  C) file's buffer    : %s")
             (plist-get rec :text) (buffer-name) obuf
             (if live
                 " (live)"
               " (DEAD — fall back to?)")
             (or (plist-get rec :file) "<none — *scratch*-like>"))))

(defun eehp-copy (cand)
  (interactive "sEntry: ")
  (kill-new (plist-get (eehp--rec-at cand) :text))
  (message "copied sexp"))

(defun eehp-insert (cand)
  (interactive "sEntry: ")
  (insert (plist-get (eehp--rec-at cand) :text)))

(defun eehp-edit-then-eval (cand)
  (interactive "sEntry: ")
  (pop-to-buffer (get-buffer-create "*eehp edit*"))
  (emacs-lisp-mode)
  (erase-buffer)
  (insert (plist-get (eehp--rec-at cand) :text))
  (message "edit, then (prototype) C-c C-c would re-eval"))

(defun eehp-forget (cand)
  (interactive "sEntry: ")
  (setq eehp--store (cl-remove (eehp--rec-at cand) eehp--store))
  (message "forgot entry"))

(with-eval-after-load 'embark
  (defvar-keymap eehp-embark-map
    :doc "Prototype Embark actions for eval-history entries."
    :parent
    embark-general-map
    "R"
    #'eehp-reeval
    "w"
    #'eehp-copy
    "i"
    #'eehp-insert
    "e"
    #'eehp-edit-then-eval
    "k"
    #'eehp-forget)
  (add-to-list 'embark-keymap-alist '(eehp-record . eehp-embark-map))
  ;; Embark needs to recover the record from the candidate string:
  (add-to-list 'embark-transformer-alist '(eehp-record . identity)))

(provide 'elisp-eval-history-picker)
;;; elisp-eval-history-picker.el ends here
