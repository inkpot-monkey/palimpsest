;;; whisperx.el --- Transcribe audio/video via WhisperX from dired -*- lexical-binding: t; -*-

;; Author: inkpotmonkey
;; Keywords: multimedia, processes, convenience

;;; Commentary:

;; Drive the WhisperX CLI (faster-whisper transcription + word-level alignment,
;; optional speaker diarization) from Emacs — primarily from dired.
;;
;; Mark one or more audio/video files in dired and run
;; `whisperx-transcribe-dired' (bound to C-c C-t in dired by default), or call
;; `whisperx-transcribe-file' on any path.  There are no per-run prompts: every
;; run uses the settings below (`whisperx-model' etc.), set once.  Language is
;; auto-detected by default, so the same command handles English, Spanish, …
;;
;; Jobs run ONE AT A TIME in the background (WhisperX already saturates the CPU,
;; so parallel jobs would only thrash).  Output files (per `whisperx-output-format')
;; are written next to the source; the originating dired buffer is reverted when a
;; job finishes so the transcript shows up.  Progress streams to the *whisperx*
;; buffer.
;;
;; This expects the `whisperx' executable on PATH (provided on stargazer via
;; hosts/stargazer/ai.nix).  Transcription is CPU-bound and slow for `large-v3'
;; (~realtime on a fast x86 CPU); pick a smaller model for quicker turnaround.

;;; Code:

(require 'dired)
(require 'subr-x)
(require 'comint)

(defgroup whisperx nil
  "Transcribe audio/video with the WhisperX CLI."
  :group 'external
  :prefix "whisperx-")

(defcustom whisperx-executable "whisperx"
  "Name or path of the WhisperX executable."
  :type 'string)

(defcustom whisperx-model "large-v3"
  "Whisper model to transcribe with, passed to WhisperX's --model.
Set once here; it is never prompted per run.  \"large-v3\" is the highest-quality
general model and the default; smaller models (\"medium\", \"small\") trade quality
for speed.  The weights are NOT installed by Nix — faster-whisper downloads them
from HuggingFace on first use and caches them under ~/.cache."
  :type 'string)

(defcustom whisperx-device "cpu"
  "Compute device passed to WhisperX (these machines have no CUDA, so \"cpu\")."
  :type 'string)

(defcustom whisperx-compute-type "int8"
  "faster-whisper compute type; \"int8\" is the CPU pick."
  :type
  '(choice
    (const "int8")
    (const "float32")
    (const "float16")
    (const "default")))

(defcustom whisperx-language nil
  "Source language code (e.g. \"en\", \"es\"), or nil to auto-detect."
  :type
  '(choice
    (const :tag "Auto-detect" nil) (string :tag "Language code")))

(defcustom whisperx-output-format "srt"
  "Output format passed to --output_format."
  :type
  '(choice
    (const "all")
    (const "srt")
    (const "vtt")
    (const "txt")
    (const "tsv")
    (const "json")))

(defcustom whisperx-batch-size 8
  "Batched-inference batch size, or nil to leave the WhisperX default."
  :type '(choice (const :tag "Default" nil) integer))

(defcustom whisperx-diarize nil
  "When non-nil, request speaker diarization (needs `whisperx-hf-token-file')."
  :type 'boolean)

(defcustom whisperx-hf-token-file nil
  "File containing a HuggingFace token (raw token) for gated pyannote models."
  :type '(choice (const :tag "None" nil) file))

(defcustom whisperx-extra-args nil
  "Extra command-line arguments appended verbatim to every WhisperX invocation."
  :type '(repeat string))

(defcustom whisperx-open-result nil
  "When non-nil, visit the produced transcript when a job finishes."
  :type 'boolean)

(defcustom whisperx-show-progress t
  "When non-nil, pop up the *whisperx* buffer when a model download starts.
Models are fetched on demand on first use (see `whisperx-model'); this makes
that one-time download visible instead of looking like a stalled transcription."
  :type 'boolean)

(defconst whisperx--buffer "*whisperx*"
  "Name of the buffer collecting WhisperX process output.")

(defvar whisperx--queue nil
  "FIFO of pending jobs.  Each element is a plist (:file :dir :dired).")

(defvar whisperx--process nil
  "The currently running WhisperX process, or nil when idle.")

(defvar whisperx--current nil
  "Plist of the job currently being processed, or nil.")

(defvar whisperx--downloading nil
  "Non-nil once a model download has been detected for the current job.")

(defconst whisperx--download-regexp
  "Downloading\\|Fetching [0-9]+ files\\|[0-9]+%|"
  "Output pattern signalling WhisperX is downloading a model (HF/torch).
The \"%|\" form matches tqdm download bars; transcription progress prints
\"Progress: N%...\" without the pipe, so the two don't collide.")

(defun whisperx--hf-token ()
  "Return the HuggingFace token string, or nil."
  (when (and whisperx-hf-token-file
             (file-readable-p whisperx-hf-token-file))
    (string-trim
     (with-temp-buffer
       (insert-file-contents whisperx-hf-token-file)
       (buffer-string)))))

(defun whisperx--build-args (file dir)
  "Build the WhisperX argument list for FILE writing into DIR.
All settings come from the `whisperx-*' variables (set once, never per-run)."
  (append
   (list
    (expand-file-name file)
    "--model"
    whisperx-model
    "--device"
    whisperx-device
    "--compute_type"
    whisperx-compute-type
    "--output_dir"
    (expand-file-name dir)
    "--output_format"
    whisperx-output-format
    "--print_progress"
    "True")
   (when whisperx-batch-size
     (list "--batch_size" (number-to-string whisperx-batch-size)))
   (when whisperx-language
     (list "--language" whisperx-language))
   (when whisperx-diarize
     (append
      (list "--diarize")
      (when-let ((tok (whisperx--hf-token)))
        (list "--hf_token" tok))))
   whisperx-extra-args))

(defun whisperx--log (fmt &rest args)
  "Append a line formatted from FMT and ARGS to the *whisperx* buffer."
  (with-current-buffer (get-buffer-create whisperx--buffer)
    (goto-char (point-max))
    (let ((inhibit-read-only t))
      (insert (apply #'format fmt args) "\n"))))

(defun whisperx--filter (proc string)
  "Insert STRING from PROC into the log buffer and surface download activity.
Carriage returns are honoured (`comint-carriage-motion') so tqdm progress bars
render as one updating line.  The first download seen per job is announced and,
when `whisperx-show-progress' is set, pops up the log buffer — so the one-time
model fetch is visible instead of looking like a stalled transcription."
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (let ((inhibit-read-only t)
            (moving (= (point) (process-mark proc))))
        (save-excursion
          (goto-char (process-mark proc))
          (let ((start (point)))
            (insert string)
            (comint-carriage-motion start (point)))
          (set-marker (process-mark proc) (point)))
        (when moving
          (goto-char (process-mark proc))))))
  (when (and (not whisperx--downloading)
             (string-match-p whisperx--download-regexp string))
    (setq whisperx--downloading t)
    (message
     "WhisperX: downloading model data (one-time, several GB) — watch %s"
     whisperx--buffer)
    (when whisperx-show-progress
      (display-buffer whisperx--buffer))))

(defun whisperx--sentinel (proc event)
  "Process sentinel: report on PROC's EVENT and start the next queued job."
  (when (memq (process-status proc) '(exit signal))
    (let* ((job whisperx--current)
           (file (plist-get job :file))
           (dir (plist-get job :dir))
           (ok
            (and (eq (process-status proc) 'exit)
                 (zerop (process-exit-status proc)))))
      (setq
       whisperx--process nil
       whisperx--current nil)
      (if ok
          (progn
            (whisperx--log "✓ done: %s" file)
            (message "WhisperX: finished %s"
                     (file-name-nondirectory file))
            (let ((dired-buf (plist-get job :dired)))
              (when (buffer-live-p dired-buf)
                (with-current-buffer dired-buf
                  (revert-buffer))))
            (when whisperx-open-result
              (let ((out
                     (expand-file-name (concat
                                        (file-name-base file) "."
                                        (if (string=
                                             whisperx-output-format
                                             "all")
                                            "txt"
                                          whisperx-output-format))
                                       dir)))
                (when (file-exists-p out)
                  (find-file-other-window out)))))
        (whisperx--log "✗ FAILED (%s): %s" (string-trim event) file)
        (message "WhisperX: FAILED on %s — see %s"
                 (file-name-nondirectory file)
                 whisperx--buffer)
        (display-buffer whisperx--buffer))
      (whisperx--start-next))))

(defun whisperx--start-next ()
  "Start the next queued job, if any and nothing is already running."
  (when (and whisperx--queue (not whisperx--process))
    (unless (executable-find whisperx-executable)
      (setq whisperx--queue nil)
      (user-error "WhisperX: executable %S not found on PATH"
                  whisperx-executable))
    (let* ((job (pop whisperx--queue))
           (file (plist-get job :file))
           (dir (plist-get job :dir))
           (args (whisperx--build-args file dir)))
      (setq
       whisperx--current job
       whisperx--downloading nil)
      (whisperx--log "\n$ %s %s\n  (%d more queued)"
                     whisperx-executable
                     (string-join args " ")
                     (length whisperx--queue))
      (message "WhisperX: transcribing %s%s"
               (file-name-nondirectory file)
               (if whisperx--queue
                   (format " (%d more queued)"
                           (length whisperx--queue))
                 ""))
      (setq whisperx--process
            (make-process
             :name "whisperx"
             :buffer whisperx--buffer
             :command (cons whisperx-executable args)
             :noquery t
             :connection-type 'pipe
             :filter #'whisperx--filter
             :sentinel #'whisperx--sentinel)))))

(defun whisperx--enqueue (files &optional dired-buffer)
  "Queue FILES for transcription, reverting DIRED-BUFFER when each finishes."
  (dolist (file files)
    (setq whisperx--queue
          (append
           whisperx--queue
           (list
            (list
             :file file
             :dir
             (file-name-directory (expand-file-name file))
             :dired dired-buffer)))))
  (whisperx--start-next))

;;;###autoload
(defun whisperx-transcribe-dired ()
  "Transcribe the marked files (or file at point) in dired with WhisperX.
Uses the `whisperx-*' settings as configured (model etc. are set once, not
prompted).  Jobs run sequentially in the background; transcripts land beside
each source file."
  (interactive)
  (let ((files (dired-get-marked-files nil nil #'file-regular-p)))
    (unless files
      (user-error "No (regular) files selected"))
    (whisperx--enqueue files (current-buffer))))

;;;###autoload
(defun whisperx-transcribe-file (file)
  "Transcribe FILE with WhisperX using the configured settings."
  (interactive (list (read-file-name "Audio/video file: " nil nil t)))
  (whisperx--enqueue (list file)))

;;;###autoload
(defun whisperx-show-log ()
  "Pop to the *whisperx* output buffer."
  (interactive)
  (pop-to-buffer (get-buffer-create whisperx--buffer)))

(defun whisperx-cancel ()
  "Cancel the running WhisperX job and clear the queue."
  (interactive)
  (setq whisperx--queue nil)
  (when (and whisperx--process (process-live-p whisperx--process))
    (interrupt-process whisperx--process)
    (message "WhisperX: cancelled current job and cleared queue")))

(provide 'whisperx)
;;; whisperx.el ends here
