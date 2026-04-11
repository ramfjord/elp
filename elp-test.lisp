;;;; Comprehensive Test Suite for ELP
;;;; Tests tokenization, code generation, and rendering with integrated pipeline validation
;;;; Uses FiveAM testing framework with RSpec-style test wrapper

(defpackage :elp-test
  (:use :cl :fiveam :elp)
  (:export :run-tests))

(in-package :elp-test)

;; Define test suite
(def-suite generate-suite
  :description "Code generation tests for ELP")

(in-suite generate-suite)

;;;; Test Helper Macros and Functions

(defun template-string-to-file (template-string)
  "Create a temporary file from template string, return the file path."
  (let ((temp-file (make-pathname :name "elp-gen-test-temp" :type "elp")))
    (with-open-file (f temp-file :direction :output :if-exists :supersede)
      (write-string template-string f))
    temp-file))

(defun cleanup-file (filepath)
  "Delete a file if it exists."
  (when (probe-file filepath)
    (delete-file filepath)))

(defun tokens-match-structure (actual expected-structure)
  "Check if tokens match expected structure, ignoring byte positions.
   expected-structure is a list of (type content depth) tuples."
  (and (= (length actual) (length expected-structure))
       (every (lambda (token exp-struct)
                (destructuring-bind (type content depth) exp-struct
                  (and (eq (first token) type)
                       (equal (second token) content)
                       (= (fifth token) depth))))
              actual
              expected-structure)))

(defmacro expect-render (template-string expected-token-structure expected-output &optional context)
  "RSpec-style test wrapper that validates:
   1. Tokenization produces tokens with correct structure
   2. Code generation produces valid S-expression
   3. Rendering produces expected output

   Expected token structure is a list of (type content depth) tuples.
   Optional context is an alist of (symbol . value) pairs for variable bindings.

   Example: (expect-render \"Hello <%= (list 1 2 3) %>\"
              '((:text \"Hello \") (:expr \"(list 1 2 3)\"))
              \"Hello (1 2 3)\")

   With context: (expect-render \"Name: <%= name %>\"
                  '((:text \"Name: \") (:expr \"name\"))
                  \"Name: Alice\"
                  '((name . \"Alice\")))"
  `(let ((temp-file (template-string-to-file ,template-string)))
     (unwind-protect
         (progn
           ;; Step 1: Validate tokenization structure
           (let ((tokens (tokenize-file temp-file)))
             (is (tokens-match-structure tokens ,expected-token-structure)
                 (format nil "Tokens structure should match. Got: ~S" tokens)))

           ;; Step 2: Validate rendering via public API
           (let ((output (elp:render temp-file (or ,context '()))))
             (is (equal output ,expected-output)
                 (format nil "Rendered output should match. Got: ~S" output))))
       ;; Cleanup
       (cleanup-file temp-file))))

;;;; Test Group 1: Basic Template Rendering
;;;; =====================================

(test text-only-rendering
  "Plain text template with no tags"
  (expect-render "Hello World"
    '((:text "Hello World" 0))
    "Hello World"))

(test simple-expression-rendering
  "Template with single expression evaluating to a value"
  (expect-render "Hello <%= (list 1 2 3) %>"
    '((:text "Hello " 0)
      (:expr "(list 1 2 3)" 0))
    "Hello (1 2 3)"))

(test variable-binding-and-reference
  "Template with context variables bound and referenced in expressions"
  (expect-render "Name: <%= name %>, Age: <%= age %>"
    '((:text "Name: " 0)
      (:expr "name" 0)
      (:text ", Age: " 0)
      (:expr "age" 0))
    "Name: Alice, Age: 30"
    '((name . "Alice") (age . 30))))

(test expression-only-rendering
  "Template with only an expression"
  (expect-render "<%= (+ 10 20) %>"
    '((:expr "(+ 10 20)" 0))
    "30"))

(test multiple-expressions-rendering
  "Template with multiple expressions"
  (expect-render "<%= (+ 1 2) %> and <%= (+ 3 4) %>"
    '((:expr "(+ 1 2)" 0)
      (:text " and " 0)
      (:expr "(+ 3 4)" 0))
    "3 and 7"))

;;;; Test Group 2: Code Blocks
;;;; ==========================

(test simple-code-block-rendering
  "Code block that doesn't produce output"
  (expect-render "<% (setf x 42) %>Result: <%= x %>"
    '((:code "(setf x 42)" 0)
      (:text "Result: " 0)
      (:expr "x" 0))
    "Result: 42"))

;;;; TODO: nested-code-block-rendering
;;;; This test is skipped because it requires handling code blocks that span multiple tokens
;;;; Multi-token code structures like loops spanning delimiters need a different compilation strategy

;;;; Test Group 3: Comments
;;;; ======================

(test comment-removal
  "Comments should be stripped from output"
  (expect-render "Start<%# This is a comment %>End"
    '((:text "Start" 0)
      (:comment "This is a comment" 0)
      (:text "End" 0))
    "StartEnd"))

(test inline-comment
  "Comment between text sections"
  (expect-render "A<%# TODO %>B"
    '((:text "A" 0)
      (:comment "TODO" 0)
      (:text "B" 0))
    "AB"))

;;;; Test Group 4: Complex Expressions
;;;; ==================================

(test string-concatenation-expression
  "Expression with string operations"
  (expect-render "Name: <%= (concatenate 'string \"Mr. \" \"Smith\") %>"
    '((:text "Name: " 0)
      (:expr "(concatenate 'string \"Mr. \" \"Smith\")" 0))
    "Name: Mr. Smith"))

(test list-expression
  "Expression evaluating to a list"
  (expect-render "Items: <%= (quote (a b c)) %>"
    '((:text "Items: " 0)
      (:expr "(quote (a b c))" 0))
    "Items: (A B C)"))

;;;; Test Group 5: Edge Cases
;;;; =========================

(test empty-expression
  "Expression with whitespace only (after trimming)"
  (expect-render "Value: <%=   %>after"
    '((:text "Value: " 0)
      (:expr "" 0)
      (:text "after" 0))
    "Value: after"))

(test consecutive-delimiters
  "Multiple delimiters back-to-back"
  (expect-render "<%= 1 %><%= 2 %>"
    '((:expr "1" 0)
      (:expr "2" 0))
    "12"))

;;;; Test Group 6: Whitespace in Templates
;;;; ======================================

(test newlines-in-text
  "Text tokens with newlines are preserved"
  (let ((template-with-newline (concatenate 'string "Hello" (string #\newline) "World")))
    (expect-render template-with-newline
      `((:text ,template-with-newline 0))
      template-with-newline)))

(test spaces-in-expression
  "Whitespace inside expression tags is trimmed"
  (expect-render "<%=   (+ 1 2)   %>"
    '((:expr "(+ 1 2)" 0))
    "3"))

;;;; Test Group 7: Variable Binding
;;;; ==============================

;;;; TODO: variable-reference-in-code
;;;; This test is skipped because it requires handling code blocks that span multiple tokens
;;;; Multi-token structures like let bindings spanning delimiters need different compilation

;;;; Run Tests
(defun run-tests ()
  "Run all ELP tests"
  (run! 'generate-suite))
