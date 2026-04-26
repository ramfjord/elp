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

(defmacro expect-render (template-string expected-output &optional context)
  "RSpec-style test wrapper: render TEMPLATE-STRING (with optional
   CONTEXT alist of variable bindings) and assert the output equals
   EXPECTED-OUTPUT."
  `(let ((temp-file (template-string-to-file ,template-string)))
     (unwind-protect
          (let ((output (with-output-to-string (s)
                          (elp:render temp-file (or ,context '()) s))))
            (is (equal output ,expected-output)
                (format nil "Rendered output should match. Got: ~S" output)))
       (cleanup-file temp-file))))

;;;; Test Group 1: Basic Template Rendering
;;;; =====================================

(test text-only-rendering
  "Plain text template with no tags"
  (expect-render "Hello World" "Hello World"))

(test simple-expression-rendering
  "Template with single expression evaluating to a value"
  (expect-render "Hello <%= (list 1 2 3) %>" "Hello (1 2 3)"))

(test variable-binding-and-reference
  "Template with context variables bound and referenced in expressions"
  (expect-render "Name: <%= name %>, Age: <%= age %>"
    "Name: Alice, Age: 30"
    '((name . "Alice") (age . 30))))

(test multiple-expressions-rendering
  "Template with multiple expressions"
  (expect-render "<%= (+ 1 2) %> and <%= (+ 3 4) %>" "3 and 7"))

;;;; Test Group 2: Code Blocks
;;;; ==========================

(test simple-code-block-rendering
  "Code block that doesn't produce output"
  (expect-render "<% (setf x 42) %>Result: <%= x %>" "Result: 42"))

;;;; Test Group 3: Comments
;;;; ======================

(test comment-removal
  "Comments should be stripped from output"
  (expect-render "Start<%# This is a comment %>End" "StartEnd"))

;;;; Test Group 4: Edge Cases
;;;; ========================

(test empty-expression
  "<%= %> with whitespace-only body is skipped (no output, no error)."
  (expect-render "Value: <%=   %>after" "Value: after"))

(test consecutive-delimiters
  "Multiple delimiters back-to-back"
  (expect-render "<%= 1 %><%= 2 %>" "12"))

;;;; Test Group 7: Error Reporting
;;;; ==============================
;;;; Column semantics: the reported column is the first byte after the
;;;; opening delimiter (<%= or <%) — i.e. the start of the expression/code
;;;; content region, whitespace included. This is a v1 approximation;
;;;; column is not refined further within the expression.

(defun render-error (template-string &optional context)
  "Render TEMPLATE-STRING from a temp file and capture any elp-template-error."
  (let ((temp-file (template-string-to-file template-string))
        (sink (make-broadcast-stream)))
    (unwind-protect
         (handler-case
             (progn (elp:render temp-file (or context '()) sink) nil)
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

;;;; Test Group 8b: Spanning-paren constructs (multi-block forms)
;;;; ============================================================
;;;; These constructs work because the standard Lisp reader is in the
;;;; middle of building a list when the gray stream transitions
;;;; through %> ... text ... <%. Each one exercises a different
;;;; control-flow construct that splits its body across two or more
;;;; <% ... %> blocks with literal text in between.

(test spanning-dolist-literal-list
  "dolist body iterating over a literal list, emitting each element."
  (expect-render "<% (dolist (x '(1 2 3)) %><%= x %><% ) %>" "123"))

(test spanning-nested-let
  "Two LET bindings split across four <% %> blocks; the inner
   expression references both outer variables."
  (expect-render
      "<% (let ((y 10)) %><% (let ((z 20)) %><%= (+ y z) %><% ) %><% ) %>"
    "30"))

(test spanning-when
  "WHEN with a multi-block body emits its inner text only when the
   test is true."
  (expect-render "<% (when t %>visible<% ) %>" "visible"))

(test spanning-when-false-suppresses
  "WHEN with a false test suppresses the entire spanned body,
   including any literal text inside it."
  (expect-render "before<% (when nil %>hidden<% ) %>after" "beforeafter"))

(test spanning-progn-with-text
  "PROGN body split across blocks: literal text and expression
   results both emit."
  (expect-render "<% (progn %>a<%= 1 %>b<% ) %>" "a1b"))


;;;; Test Group 8c: Close-trim (`-%>`)
;;;; ==================================
;;;; `-%>` strips at most one trailing `\r?\n` after the close
;;;; delimiter. Applies to all three tag flavors: `<%`, `<%=`, `<%#`.

(test close-trim-on-code-block
  "<% ... -%>\\n drops the trailing newline after the code block."
  (expect-render
      (format nil "before~%<% (setf x 1) -%>~%after~%")
      (format nil "before~%after~%")))

(test close-trim-on-expr
  "<%= ... -%>\\n drops the trailing newline after the expression."
  (expect-render
      (format nil "<%= 42 -%>~%tail")
      "42tail"))

(test close-trim-on-comment
  "<%# ... -%>\\n drops the trailing newline after a comment."
  (expect-render
      (format nil "head~%<%# silenced -%>~%tail")
      (format nil "head~%tail")))

(test close-trim-handles-crlf
  "Trim consumes `\\r\\n` as a single line break, not just `\\n`."
  (expect-render
      (format nil "<% (setf x 1) -%>~C~Ctail" #\Return #\Newline)
      "tail"))

(test close-trim-no-newline-after-is-fine
  "If no newline follows `-%>`, no bytes are consumed beyond the close."
  (expect-render "<%= 7 -%>x" "7x"))

(test bare-close-still-keeps-newline
  "Plain `%>` (no trim) is unchanged: trailing newline survives."
  (expect-render
      (format nil "<%= 1 %>~%after")
      (format nil "1~%after")))

(test bare-close-on-code-still-keeps-newline
  "Plain `<% %>` regression — trailing newline still emitted."
  (expect-render
      (format nil "<% (setf x 1) %>~%after")
      (format nil "~%after")))

(test close-trim-on-empty-expr
  "`<%= -%>\\n` (whitespace-only body with trim) skips block AND newline."
  (expect-render
      (format nil "head<%=  -%>~%tail")
      "headtail"))

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

(defun stream-read-form (template-string)
  "Wrap TEMPLATE-STRING in a TEMPLATE-STREAM and READ one Lisp form
   from it. Useful for asserting the standard reader walks the
   synthesized character stream cleanly — what the rest of the engine
   ultimately consumes."
  (multiple-value-bind (s cleanup) (template-stream-of template-string)
    (unwind-protect (read s nil :eof)
      (funcall cleanup))))

(test stream-empty-template
  "Empty input (zero-byte mapping) reads as immediate EOF.
   Constructed without mmap because Linux rejects mmap of size 0;
   RENDER short-circuits before reaching here, but the stream class
   itself must handle the case cleanly."
  (let ((s (make-instance 'elp::template-stream
                          :ptr (cffi:null-pointer) :size 0)))
    (is (eq :eof (read-char s nil :eof)))))

(test stream-read-on-text-only
  "(READ stream) on a text-only template returns the wrapper form."
  (let ((form (stream-read-form "Hi")))
    (is (equal form '(elp::write-output-range elp::*template-ptr* 0 2)))))

(test stream-read-on-code-block
  "(READ stream) on a <% ... %> block returns the embedded form,
   stripped of template syntax."
  (let ((form (stream-read-form "<% (+ 1 2) %>")))
    (is (equal form '(+ 1 2)))))

(test stream-read-on-expr
  "(READ stream) on <%= 1 %> returns the let/format wrapper that the
   engine evaluates — the content-span literal records the byte range
   for runtime error reporting."
  (let ((form (stream-read-form "<%= 1 %>")))
    (is (equal form
               '(let ((elp::*current-template-span* '(3 6)))
                 (format t "~A" 1))))))

(test stream-read-on-comment-then-text
  "(READ stream) skips a leading <%# ... %> and returns the trailing
   text wrapper as the first form."
  (let ((form (stream-read-form "<%# x %>tail")))
    (is (equal form '(elp::write-output-range elp::*template-ptr* 8 12)))))

;;;; Test Group 11: template-stream position-map (commit 3)
;;;; =====================================================

(defun stream-position-map-after-drain (template-string)
  "Drain TEMPLATE-STRING through a template-stream and return the
   final position-map (oldest first)."
  (multiple-value-bind (s cleanup) (template-stream-of template-string)
    (unwind-protect
         (progn
           (loop for c = (read-char s nil :eof) until (eq c :eof))
           (reverse (elp::ts-position-map s)))
      (funcall cleanup))))

(test position-map-text-only-empty
  "Text-only templates have no mmap-content runs, so no checkpoints."
  (is (equal '() (stream-position-map-after-drain "Hello"))))

(test position-map-comment-only-empty
  "<%# %> alone produces no characters and no checkpoints."
  (is (equal '() (stream-position-map-after-drain "<%# anything %>"))))

(test position-map-code-block
  "A <% ... %> code block pushes one checkpoint anchored at its first
   body byte, keyed at the reader position where the body starts."
  ;; Bytes 0-1 = '<%'; byte 2 is the first code-body byte (' ').
  ;; No leading text wrapper, so reader-pos = 0 when :lisp begins.
  (is (equal '((0 . 2)) (stream-position-map-after-drain "<% (foo) %>"))))

(test position-map-text-then-code
  "Leading text emits a wrapper (synth) before the code body. The
   checkpoint key is the wrapper length (chars-read after drain),
   anchored at the code body's first byte."
  ;; "ab<% (foo) %>cd" — wrapper for [0,2) is 50 chars; body at byte 4.
  (let ((expected-key
          (length (format nil
                          "(elp::write-output-range elp::*template-ptr* ~D ~D) "
                          0 2))))
    (is (equal `((,expected-key . 4))
               (stream-position-map-after-drain "ab<% (foo) %>cd")))))

(test position-map-expr-block
  "An <%= ... %> block pushes one checkpoint anchored at its first
   body byte, keyed AFTER the let-prefix is drained."
  ;; "<%= 1 %>" — content [3,6); prefix is the let/format wrapper.
  (let ((expected-key
          (length (format nil
                          "(let ((elp::*current-template-span* '(~D ~D))) (format t \"~~A\" "
                          3 6))))
    (is (equal `((,expected-key . 3))
               (stream-position-map-after-drain "<%= 1 %>")))))

(test stream-byte-position-inside-code-body
  "STREAM-BYTE-POSITION at a reader position inside a code body
   returns the corresponding mmap byte."
  ;; "<% (foo) %>": :lisp run starts at chars-read=0, byte 2.
  ;; chars-read=3 corresponds to byte 5 ('o' in "foo").
  (multiple-value-bind (s cleanup) (template-stream-of "<% (foo) %>")
    (unwind-protect
         (progn
           ;; Read 3 chars: ' ', '(', 'f'. Reader-pos = 3, next byte = 5.
           (read-char s) (read-char s) (read-char s)
           (is (= 3 (elp::ts-chars-read s)))
           (is (= 5 (elp::stream-byte-position s))))
      (funcall cleanup))))

(test stream-byte-position-before-first-checkpoint
  "Reader positions that precede every checkpoint return NIL — the
   stream cannot anchor them to a source byte."
  ;; "Hello" has no checkpoints; any query returns NIL.
  (multiple-value-bind (s cleanup) (template-stream-of "Hello")
    (unwind-protect
         (is (null (elp::stream-byte-position s 5)))
      (funcall cleanup))))

(test stream-byte-position-roundtrip-mid-expr-body
  "Inside the body of an <%= ... %> block, STREAM-BYTE-POSITION
   returns the exact mmap byte for each character read."
  ;; "<%= xy %>" — body bytes [3,6) = ' ', 'x', 'y'. After draining the
  ;; let-prefix the checkpoint key equals chars-read; reading further
  ;; advances key+1 → byte 4, key+2 → byte 5.
  (multiple-value-bind (s cleanup) (template-stream-of "<%= xy %>")
    (unwind-protect
         (progn
           (loop for c = (read-char s nil :eof) until (eq c :eof))
           (let* ((map (elp::ts-position-map s))
                  (key (caar map)))
             (is (= 3 (elp::stream-byte-position s key)))
             (is (= 4 (elp::stream-byte-position s (1+ key))))
             (is (= 5 (elp::stream-byte-position s (+ 2 key))))))
      (funcall cleanup))))

;;;; Test Group 12: Codegen — what does build-render-form actually produce?
;;;; ======================================================================
;;;; This test pins down the exact sexp the engine builds for a small
;;;; mixed fixture. Reading the test source is the canonical way to see
;;;; an example of generated code; running it catches accidental
;;;; regressions in the wrapper format.

(test build-render-form-shape
  "Generated body sexp for a fixture mixing text, an expression, a
   dolist spanning blocks, and a context binding. Reading the EXPECTED
   form below is the documentation: it shows write-output-range
   wrapping each text span, a let/format wrapper around each <%= %>
   carrying the byte range for runtime error reporting, and the dolist
   body containing the inner forms (the spanning-paren win — the
   reader appends them naturally because it is mid-list when the
   stream transitions through %> ... text ... <%)."
  (let* ((tmpl     "Hi <%= name %>!
<% (dolist (x '(1 2 3)) %>* <%= x %>
<% ) %>")
         (path     (template-string-to-file tmpl))
         (expected '(let ((name '"Alice"))
                     (progn
                      (elp::write-output-range elp::*template-ptr* 0 3)
                      (let ((elp::*current-template-span* '(6 12)))
                        (format t "~A" name))
                      (elp::write-output-range elp::*template-ptr* 14 16)
                      (dolist (x '(1 2 3))
                        (elp::write-output-range elp::*template-ptr* 42 44)
                        (let ((elp::*current-template-span* '(47 50)))
                          (format t "~A" x))
                        (elp::write-output-range elp::*template-ptr* 52 53))))))
    (unwind-protect
         (multiple-value-bind (ptr size fd) (elp::%mmap-open path)
           (unwind-protect
                (let ((generated (elp::build-render-form path ptr size
                                                         '((name . "Alice")))))
                  (is (equal generated expected)
                      (format nil "Generated form should match.~%Got:~%~S"
                              generated)))
             (elp::%mmap-close ptr size fd)))
      (cleanup-file path))))

;;;; Run Tests
(defun run-tests ()
  "Run all ELP tests"
  (run! 'generate-suite))
