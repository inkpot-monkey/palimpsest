;;; claude-tui-test.el --- Tests for claude-tui -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the pure grid→trigger core of claude-tui: given a terminal row,
;; a cursor column, and a snippet alist, resolve the trailing word to its
;; snippet cell.  The interactive command (`claude-tui-tab-expand') and the
;; copy-mode shim are NOT exercised here — they need a live ghostel terminal;
;; the logic they wrap is covered below.
;;
;; Run standalone:
;;   emacs --batch -L . -l ert -l claude-tui-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'claude-tui)

(defconst claude-tui-test--snips
  '(("yr" . "go with your recommendations")
    ("wdyt" . "what do you think?")
    ("co-op" . "cooperate"))
  "Fixed snippet alist for the tests, independent of the defcustom default.")

(ert-deftest claude-tui-test-trigger-at-end ()
  "A trailing trigger with the cursor at end of row resolves to its cell."
  (should
   (equal
    '("yr" . "go with your recommendations")
    (claude-tui--trigger-at "please yr" nil claude-tui-test--snips)))
  ;; col at the end of the row is the same as nil
  (should
   (equal
    '("yr" . "go with your recommendations")
    (claude-tui--trigger-at "please yr" 9 claude-tui-test--snips))))

(ert-deftest claude-tui-test-trigger-reads-left-of-cursor ()
  "Only the word left of the cursor counts, not text to its right."
  ;; cursor after \"yr\" (col 2), \"wdyt\" sits to the right -> yr wins
  (should
   (equal
    "go with your recommendations"
    (cdr
     (claude-tui--trigger-at "yr wdyt" 2 claude-tui-test--snips))))
  ;; cursor mid-word (col 5 of \"foo yr\" = after \"y\") -> partial \"y\", no match
  (should-not
   (claude-tui--trigger-at "foo yr" 5 claude-tui-test--snips)))

(ert-deftest claude-tui-test-trigger-hyphenated ()
  "A hyphenated trigger matches ([[:alnum:]-]+ includes the hyphen)."
  (should
   (equal
    '("co-op" . "cooperate")
    (claude-tui--trigger-at
     "let us co-op" nil claude-tui-test--snips))))

(ert-deftest claude-tui-test-trigger-absent ()
  "A trailing word that is not a trigger yields nil (TAB is forwarded)."
  (should-not
   (claude-tui--trigger-at "nomatch" nil claude-tui-test--snips))
  ;; a trigger as a mere substring of the trailing word does not count
  (should-not
   (claude-tui--trigger-at "xyr" nil claude-tui-test--snips)))

(ert-deftest claude-tui-test-trigger-no-word ()
  "An empty row, a cursor at column 0, or trailing non-word chars yield nil."
  (should-not (claude-tui--trigger-at "" 0 claude-tui-test--snips))
  (should-not (claude-tui--trigger-at "yr" 0 claude-tui-test--snips))
  (should-not
   (claude-tui--trigger-at "yr " nil claude-tui-test--snips)))

(ert-deftest claude-tui-test-trigger-col-out-of-range ()
  "A column past the row length falls back to scanning the whole row."
  (should
   (equal
    '("yr" . "go with your recommendations")
    (claude-tui--trigger-at "yr" 99 claude-tui-test--snips))))

(provide 'claude-tui-test)
;;; claude-tui-test.el ends here
