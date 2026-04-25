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
   expected-structure is a list of (type content) tuples."
  (and (= (length actual) (length expected-structure))
       (every (lambda (token exp-struct)
                (destructuring-bind (type content) exp-struct
                  (and (eq (first token) type)
                       (equal (second token) content))))
              actual
              expected-structure)))

(defmacro expect-render (template-string expected-token-structure expected-output &optional context)
  "RSpec-style test wrapper that validates:
   1. Tokenization produces tokens with correct structure
   2. Code generation produces valid S-expression
   3. Rendering produces expected output

   Expected token structure is a list of (type content) tuples.
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
    '((:text "Hello World"))
    "Hello World"))

(test simple-expression-rendering
  "Template with single expression evaluating to a value"
  (expect-render "Hello <%= (list 1 2 3) %>"
    '((:text "Hello ")
      (:expr "(list 1 2 3)"))
    "Hello (1 2 3)"))

(test variable-binding-and-reference
  "Template with context variables bound and referenced in expressions"
  (expect-render "Name: <%= name %>, Age: <%= age %>"
    '((:text "Name: ")
      (:expr "name")
      (:text ", Age: ")
      (:expr "age"))
    "Name: Alice, Age: 30"
    '((name . "Alice") (age . 30))))

(test expression-only-rendering
  "Template with only an expression"
  (expect-render "<%= (+ 10 20) %>"
    '((:expr "(+ 10 20)"))
    "30"))

(test multiple-expressions-rendering
  "Template with multiple expressions"
  (expect-render "<%= (+ 1 2) %> and <%= (+ 3 4) %>"
    '((:expr "(+ 1 2)")
      (:text " and ")
      (:expr "(+ 3 4)"))
    "3 and 7"))

;;;; Test Group 2: Code Blocks
;;;; ==========================

(test simple-code-block-rendering
  "Code block that doesn't produce output"
  (expect-render "<% (setf x 42) %>Result: <%= x %>"
    '((:code "(setf x 42)")
      (:text "Result: ")
      (:expr "x"))
    "Result: 42"))

(test loop-with-inner-template
  "Loop code block spanning multiple tokens renders inner template for each iteration"
  (let ((newline (string #\newline)))
    (expect-render (concatenate 'string "<% (dolist (item items) %>Item: <%= item %>" newline "<% ) %>")
      `((:code "(dolist (item items)")
        (:text "Item: ")
        (:expr "item")
        (:text ,newline)
        (:code ")"))
      (format nil "Item: foo~%Item: bar~%Item: baz~%")
      '((items . ("foo" "bar" "baz"))))))

;;;; Test Group 3: Comments
;;;; ======================

(test comment-removal
  "Comments should be stripped from output"
  (expect-render "Start<%# This is a comment %>End"
    '((:text "Start")
      (:comment "This is a comment")
      (:text "End"))
    "StartEnd"))

(test inline-comment
  "Comment between text sections"
  (expect-render "A<%# TODO %>B"
    '((:text "A")
      (:comment "TODO")
      (:text "B"))
    "AB"))

;;;; Test Group 4: Complex Expressions
;;;; ==================================

(test string-concatenation-expression
  "Expression with string operations"
  (expect-render "Name: <%= (concatenate 'string \"Mr. \" \"Smith\") %>"
    '((:text "Name: ")
      (:expr "(concatenate 'string \"Mr. \" \"Smith\")"))
    "Name: Mr. Smith"))

(test list-expression
  "Expression evaluating to a list"
  (expect-render "Items: <%= (quote (a b c)) %>"
    '((:text "Items: ")
      (:expr "(quote (a b c))"))
    "Items: (A B C)"))

;;;; Test Group 5: Edge Cases
;;;; =========================

(test empty-expression
  "Expression with whitespace only (after trimming)"
  (expect-render "Value: <%=   %>after"
    '((:text "Value: ")
      (:expr "")
      (:text "after"))
    "Value: after"))

(test consecutive-delimiters
  "Multiple delimiters back-to-back"
  (expect-render "<%= 1 %><%= 2 %>"
    '((:expr "1")
      (:expr "2"))
    "12"))

;;;; Test Group 6: Whitespace in Templates
;;;; ======================================

(test newlines-in-text
  "Text tokens with newlines are preserved"
  (let ((template-with-newline (concatenate 'string "Hello" (string #\newline) "World")))
    (expect-render template-with-newline
      `((:text ,template-with-newline))
      template-with-newline)))

(test spaces-in-expression
  "Whitespace inside expression tags is trimmed"
  (expect-render "<%=   (+ 1 2)   %>"
    '((:expr "(+ 1 2)"))
    "3"))

;;;; Test Group 7: Error Reporting
;;;; ==============================
;;;; Column semantics: the reported column is the first byte after the
;;;; opening delimiter (<%= or <%) — i.e. the start of the expression/code
;;;; content region, whitespace included. This is a v1 approximation;
;;;; column is not refined further within the expression.

(defun render-error (template-string &optional context)
  "Render TEMPLATE-STRING from a temp file and capture any elp-template-error."
  (let ((temp-file (template-string-to-file template-string)))
    (unwind-protect
         (handler-case (progn (elp:render temp-file (or context '())) nil)
           (elp:elp-template-error (c) c))
      (cleanup-file temp-file))))

(test runtime-error-undefined-variable
  "Runtime error signals elp-template-error pointing at the expression."
  (let ((err (render-error (format nil "hello~%<%= undefined-var %>~%"))))
    (is (typep err 'elp:elp-template-error))
    (is (= 2 (elp:elp-template-error-line err)))
    ;; Expression content starts immediately after <%= on line 2, at col 4.
    (is (= 4 (elp:elp-template-error-column err)))))

(test runtime-error-column-with-leading-whitespace
  "Column points at the expression content region (just past <%=),
   not at column 1 and not at the <."
  (let ((err (render-error (format nil "line1~%    <%=    bad-var %>~%"))))
    (is (typep err 'elp:elp-template-error))
    (is (= 2 (elp:elp-template-error-line err)))
    ;; Line 2 is "    <%=    bad-var %>"; <%= ends at col 7, content at col 8.
    (is (= 8 (elp:elp-template-error-column err)))))

(test readtime-error-unbalanced-paren
  "Read-time error inside embedded Lisp signals elp-template-error."
  (let ((err (render-error (format nil "hi~%<% (let ((x 1) %>~%"))))
    (is (typep err 'elp:elp-template-error))
    (is (typep (elp:elp-template-error-original err) 'condition))
    ;; Should point somewhere inside the template, not outside.
    (is (>= (elp:elp-template-error-line err) 1))
    (is (>= (elp:elp-template-error-column err) 1))))

;;;; Run Tests
(defun run-tests ()
  "Run all ELP tests"
  (run! 'generate-suite))
