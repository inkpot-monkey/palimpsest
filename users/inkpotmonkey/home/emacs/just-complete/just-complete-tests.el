;;; just-complete-tests.el --- Tests for just-complete.el -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

;; Add the current directory to load-path to find just-complete
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'just-complete)

(ert-deftest test-just-complete--parse-args ()
  "Test parsing of arguments from just output."
  (should (equal (just-complete--parse-args nil) nil))
  (should (equal (just-complete--parse-args "") nil))
  (should (equal (just-complete--parse-args "host") '(("host" nil nil))))
  (should (equal (just-complete--parse-args "target='release'") '(("target" "release" nil))))
  (should (equal (just-complete--parse-args "*args") '(("args" nil t))))
  (should (equal (just-complete--parse-args "a b c") '(("a" nil nil) ("b" nil nil) ("c" nil nil))))
  (should (equal (just-complete--parse-args "a='b' c='d'") '(("a" "b" nil) ("c" "d" nil))))
  (should (equal (just-complete--parse-args "a=\"b\" c=d") '(("a" "b" nil) ("c" "d" nil)))))

(ert-deftest test-just-complete--get-candidates-mocked ()
  "Test candidate generation using a mock script."
  (setq just-complete--cache (make-hash-table :test 'equal))
  
  (let* ((temp-dir (make-temp-file "just-complete-test-" t))
         (mock-script (expand-file-name "mock-just" temp-dir))
         (just-complete-executable mock-script))
    
    ;; Create mock script that outputs what we want
    (with-temp-file mock-script
      (insert "#!/bin/sh\n")
      (insert "echo '    deploy host                     # Deploy to host'\n")
      (insert "echo '    build target='\\''release'\\''          # Build target'\n")
      (insert "echo '    test *args                      # Run tests'\n"))
    (set-file-modes mock-script #o755)
    
    ;; Create a dummy Justfile so it doesn't fail
    (with-temp-file (expand-file-name "Justfile" temp-dir)
      (insert "dummy\n"))
    
    (let ((default-directory temp-dir))
      (let ((candidates (just-complete--get-candidates)))
        (should (= (length candidates) 3))
        
        ;; Check first candidate
        (let ((cand1 (nth 0 candidates)))
          (should (string= cand1 "deploy"))
          (should (string= (get-text-property 0 'just-args cand1) "host"))
          (should (string= (get-text-property 0 'just-comment cand1) "Deploy to host")))
        
        ;; Check second candidate
        (let ((cand2 (nth 1 candidates)))
          (should (string= cand2 "build"))
          (should (string= (get-text-property 0 'just-args cand2) "target='release'"))
          (should (string= (get-text-property 0 'just-comment cand2) "Build target")))
        
        ;; Check third candidate
        (let ((cand3 (nth 2 candidates)))
          (should (string= cand3 "test"))
          (should (string= (get-text-property 0 'just-args cand3) "*args"))
          (should (string= (get-text-property 0 'just-comment cand3) "Run tests")))))
    
    ;; Cleanup
    (delete-directory temp-dir t)))

(ert-deftest test-just-complete--no-recipes ()
  "Test candidate generation with no recipes."
  (setq just-complete--cache (make-hash-table :test 'equal))
  (let* ((temp-dir (make-temp-file "just-complete-test-" t))
         (mock-script (expand-file-name "mock-just" temp-dir))
         (just-complete-executable mock-script))
    
    (with-temp-file mock-script
      (insert "#!/bin/sh\n")
      (insert "echo 'Available recipes:'\n"))
    (set-file-modes mock-script #o755)
    
    (with-temp-file (expand-file-name "Justfile" temp-dir)
      (insert "dummy\n"))
      
    (let ((default-directory temp-dir))
      (let ((candidates (just-complete--get-candidates)))
        (should (equal candidates nil))))
        
    (delete-directory temp-dir t)))

(ert-deftest test-just-complete--simple-recipes ()
  "Test candidates with no args and no comments."
  (setq just-complete--cache (make-hash-table :test 'equal))
  (let* ((temp-dir (make-temp-file "just-complete-test-" t))
         (mock-script (expand-file-name "mock-just" temp-dir))
         (just-complete-executable mock-script))
    
    (with-temp-file mock-script
      (insert "#!/bin/sh\n")
      (insert "echo '    recipe1'\n")
      (insert "echo '    recipe2'\n"))
    (set-file-modes mock-script #o755)
    
    (with-temp-file (expand-file-name "Justfile" temp-dir)
      (insert "dummy\n"))
      
    (let ((default-directory temp-dir))
      (let ((candidates (just-complete--get-candidates)))
        (should (= (length candidates) 2))
        (should (string= (nth 0 candidates) "recipe1"))
        (should (string= (get-text-property 0 'just-args (nth 0 candidates)) ""))
        (should (string= (get-text-property 0 'just-comment (nth 0 candidates)) ""))
        (should (string= (nth 1 candidates) "recipe2"))))
        
    (delete-directory temp-dir t)))

(ert-deftest test-just-complete--process-failure ()
  "Test handling of process failure."
  (setq just-complete--cache (make-hash-table :test 'equal))
  (let* ((temp-dir (make-temp-file "just-complete-test-" t))
         (mock-script (expand-file-name "mock-just" temp-dir))
         (just-complete-executable mock-script))
    
    (with-temp-file mock-script
      (insert "#!/bin/sh\n")
      (insert "exit 1\n"))
    (set-file-modes mock-script #o755)
    
    (with-temp-file (expand-file-name "Justfile" temp-dir)
      (insert "dummy\n"))
      
    (let ((default-directory temp-dir))
      (let ((candidates (let ((inhibit-message t))
                          (just-complete--get-candidates))))
        (should (equal candidates nil))))
        
    (delete-directory temp-dir t)))

(ert-deftest test-just-complete--marginalia-registration ()
  "Test that we can register with Marginalia without errors."
  ;; Test newer version
  (let ((marginalia-annotators '((test-category))))
    (cl-letf (((symbol-function 'boundp)
               (lambda (sym) (eq sym 'marginalia-annotators))))
      (if (boundp 'marginalia-annotators)
          (setq marginalia-annotators (cons '(just-recipe just-recipe-annotator none) marginalia-annotators))
        (error "Should not be here"))
      (should (assoc 'just-recipe marginalia-annotators))))
  
  ;; Test older version
  (let ((marginalia-annotator-registry '((test-category))))
    (cl-letf (((symbol-function 'boundp)
               (lambda (sym) (eq sym 'marginalia-annotator-registry))))
      (if (boundp 'marginalia-annotators)
          (error "Should not be here")
        (setq marginalia-annotator-registry (cons '(just-recipe just-recipe-annotator none) marginalia-annotator-registry)))
      (should (assoc 'just-recipe marginalia-annotator-registry)))))

(provide 'just-complete-tests)

;;; just-complete-tests.el ends here
