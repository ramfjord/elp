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

(defun tokenize-mmap-of-file (pathname)
  "mmap PATHNAME, run tokenize-mmap, close. Return the token list."
  (multiple-value-bind (ptr size fd) (elp::%mmap-open pathname)
    (unwind-protect (elp::tokenize-mmap ptr size)
      (elp::%mmap-close ptr size fd))))

(defun tokens-match-structure (actual expected-structure)
  "Check if tokens match expected structure, ignoring byte positions.
   Expected-structure is a list of (type content) tuples. Content
   matching is skipped for :text and :comment tokens — the mmap-based
   tokenizer leaves their content NIL (the bytes live in the mapping)
   and the rendering check downstream is what proves the byte ranges
   are correct."
  (and (= (length actual) (length expected-structure))
       (every (lambda (token exp-struct)
                (destructuring-bind (type content) exp-struct
                  (and (eq (first token) type)
                       (or (member type '(:text :comment))
                           (equal (second token) content)))))
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
           (let ((tokens (tokenize-mmap-of-file temp-file)))
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

;;;; Test Group 8: Vectorized byte search wrappers (%memmem, %memchr)
;;;; ==================================================================

(defmacro with-ascii-buffer ((ptr len string) &body body)
  "Bind PTR/LEN to a foreign ASCII buffer holding STRING (no NUL terminator)."
  `(cffi:with-foreign-string ((,ptr ,len) ,string
                              :encoding :ascii
                              :null-terminated-p nil)
     ,@body))

(test memmem-finds-at-start
  "Needle at offset 0 returns 0."
  (with-ascii-buffer (p len "hello world")
    (is (eql 0 (elp::%memmem p len "hello")))))

(test memmem-finds-at-end
  "Needle flush against end of buffer."
  (with-ascii-buffer (p len "hello world")
    (is (eql 6 (elp::%memmem p len "world")))))

(test memmem-finds-multibyte-needle
  "ELP's actual delimiters as needles."
  ;; "a<%= x %>b" — <% at 1, %> at 7.
  (with-ascii-buffer (p len "a<%= x %>b")
    (is (eql 1 (elp::%memmem p len "<%=")))
    (is (eql 1 (elp::%memmem p len "<%")))
    (is (eql 7 (elp::%memmem p len "%>")))))

(test memmem-returns-nil-on-miss
  "Absent needle returns NIL, not 0."
  (with-ascii-buffer (p len "hello world")
    (is (null (elp::%memmem p len "ZZZ")))))

(test memmem-overlapping-matches-returns-first
  "When matches overlap, return the first (leftmost) one."
  (with-ascii-buffer (p len "aaaa")
    (is (eql 0 (elp::%memmem p len "aa")))))

(test memmem-empty-haystack
  "Zero-length haystack: any nonempty needle misses."
  (with-ascii-buffer (p len "")
    (is (zerop len))
    (is (null (elp::%memmem p 0 "x")))))

(test memchr-finds-at-start
  (with-ascii-buffer (p len "hello")
    (is (eql 0 (elp::%memchr p len (char-code #\h))))))

(test memchr-finds-at-end
  (with-ascii-buffer (p len "hello")
    (is (eql 4 (elp::%memchr p len (char-code #\o))))))

(test memchr-returns-nil-on-miss
  (with-ascii-buffer (p len "hello")
    (is (null (elp::%memchr p len (char-code #\z))))))

(test memchr-finds-newline
  "memchr is the primitive for newline counting; verify it finds one."
  (let ((s (format nil "line1~%line2~%line3")))
    (with-ascii-buffer (p len s)
      (is (eql 5 (elp::%memchr p len (char-code #\newline)))))))

;;;; Test Group 9: template-stream gray stream (commit 1: :text and :lisp only)
;;;; ============================================================================

(defun template-stream-of (template-string)
  "Materialize TEMPLATE-STRING in a temp file, mmap it, wrap it in a
   TEMPLATE-STREAM. Returns (values stream cleanup-thunk). The cleanup
   thunk closes the mmap and deletes the temp file."
  (let* ((path (template-string-to-file template-string)))
    (multiple-value-bind (ptr size fd) (elp::%mmap-open path)
      (values
       (make-instance 'elp::template-stream :ptr ptr :size size)
       (lambda ()
         (elp::%mmap-close ptr size fd)
         (cleanup-file path))))))

(defun stream-drain (template-string)
  "Wrap TEMPLATE-STRING in a TEMPLATE-STREAM and read every character
   to EOF, returning the synthesized character sequence as a string."
  (multiple-value-bind (s cleanup) (template-stream-of template-string)
    (unwind-protect
         (with-output-to-string (out)
           (loop for c = (read-char s nil :eof)
                 until (eq c :eof)
                 do (write-char c out)))
      (funcall cleanup))))

(defun stream-read-form (template-string)
  "Wrap TEMPLATE-STRING in a TEMPLATE-STREAM and READ one Lisp form
   from it. Useful for asserting the standard reader walks the
   synthesized character stream cleanly."
  (multiple-value-bind (s cleanup) (template-stream-of template-string)
    (unwind-protect (read s nil :eof)
      (funcall cleanup))))

(test stream-text-only
  "A text-only template emits a single write-output-range form."
  (let ((expected
          (format nil "(elp::write-output-range elp::*template-ptr* 0 5) ")))
    (is (equal expected (stream-drain "Hello")))))

(test stream-empty-template
  "Empty input (zero-byte mapping) reads as immediate EOF.
   Constructed without mmap because Linux rejects mmap of size 0;
   the caller in RENDER-TO-STREAM short-circuits before reaching here."
  (let ((s (make-instance 'elp::template-stream
                          :ptr (cffi:null-pointer) :size 0)))
    (is (eq :eof (read-char s nil :eof)))))

(test stream-code-only
  "<% (foo) %> produces no text-emit, just the code chars + a trailing
   space synthesized at %>."
  ;; Bytes 0..1 = '<%', 2 = ' ', 3 = '(', 4..6 = 'foo', 7 = ')',
  ;; 8 = ' ', 9..10 = '%>'. Reader sees: ' (foo) ' (from :lisp) +
  ;; ' ' (synth on %>) = ' (foo)  '.
  (is (equal " (foo)  " (stream-drain "<% (foo) %>"))))

(test stream-text-then-code
  "Alternating text and code: text emits a write-output-range wrapper,
   code passes through verbatim, %> synthesizes a single space."
  (let* ((tmpl     "a<% (b) %>c")
         (expected (concatenate 'string
                                "(elp::write-output-range elp::*template-ptr* 0 1) "
                                " (b)  "
                                "(elp::write-output-range elp::*template-ptr* 10 11) ")))
    (is (equal expected (stream-drain tmpl)))))

(test stream-code-then-text
  "Code at the start emits no leading wrapper; trailing text emits one."
  (let* ((tmpl     "<% (x) %>tail")
         (expected (concatenate 'string
                                " (x)  "
                                "(elp::write-output-range elp::*template-ptr* 9 13) ")))
    (is (equal expected (stream-drain tmpl)))))

(test stream-adjacent-code-blocks
  "Two adjacent <% %> blocks with no text between them."
  (let* ((tmpl     "<% (a) %><% (b) %>")
         (expected " (a)   (b)  "))
    (is (equal expected (stream-drain tmpl)))))

(test stream-read-on-text-only
  "(READ stream) on a text-only template returns the wrapper form."
  (let ((form (stream-read-form "Hi")))
    (is (equal form '(elp::write-output-range elp::*template-ptr* 0 2)))))

(test stream-read-on-code-block
  "(READ stream) on a code block returns the embedded form, stripped of
   template syntax."
  (let ((form (stream-read-form "<% (+ 1 2) %>")))
    (is (equal form '(+ 1 2)))))

;;;; Test Group 10: template-stream <%= and <%# (commit 2)
;;;; ====================================================

(test stream-expr-only
  "<%= 1 %> wraps the body in a (let ((*current-template-span* '(C1 C2)))
   (format t \"~A\" ... )) call. Content range is bytes [3, 6) — the
   body bytes between <%= and %>, including surrounding whitespace."
  (let* ((tmpl     "<%= 1 %>")
         (expected (concatenate 'string
                                "(let ((elp::*current-template-span* '(3 6))) (format t \"~A\" "
                                " 1 "
                                ")) ")))
    (is (equal expected (stream-drain tmpl)))))

(test stream-expr-empty-skipped
  "<%=   %> with whitespace-only body emits nothing — matches the
   existing engine's <%= empty %> behavior."
  (is (equal "" (stream-drain "<%=   %>"))))

(test stream-comment-only
  "<%# comment %> produces no characters."
  (is (equal "" (stream-drain "<%# anything in here %>"))))

(test stream-comment-between-text
  "Comment between text spans drops out, leaving two text-emit forms."
  (let* ((tmpl     "a<%# c %>b")
         (expected (concatenate 'string
                                "(elp::write-output-range elp::*template-ptr* 0 1) "
                                "(elp::write-output-range elp::*template-ptr* 9 10) ")))
    (is (equal expected (stream-drain tmpl)))))

(test stream-expr-between-text
  "<%= ... %> between text spans: text wrapper, expr let-form, text wrapper."
  (let* ((tmpl     "a<%= 1 %>b")
         (expected (concatenate 'string
                                "(elp::write-output-range elp::*template-ptr* 0 1) "
                                "(let ((elp::*current-template-span* '(4 7))) (format t \"~A\" "
                                " 1 "
                                ")) "
                                "(elp::write-output-range elp::*template-ptr* 9 10) ")))
    (is (equal expected (stream-drain tmpl)))))

(test stream-read-on-expr
  "(READ stream) on <%= 1 %> returns the wrapped let/format form."
  (let ((form (stream-read-form "<%= 1 %>")))
    (is (equal form
               '(let ((elp::*current-template-span* '(3 6)))
                 (format t "~A" 1))))))

(test stream-read-on-comment-then-text
  "(READ stream) skips a leading comment and returns the trailing text
   wrapper as the first form."
  (let ((form (stream-read-form "<%# x %>tail")))
    (is (equal form '(elp::write-output-range elp::*template-ptr* 8 12)))))

;;;; Run Tests
(defun run-tests ()
  "Run all ELP tests"
  (run! 'generate-suite))
