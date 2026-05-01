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
  "Code block can SETF a context-bound variable; the lexical
   binding is mutated, the host image is unaffected."
  (expect-render "<% (setf x 42) %>Result: <%= x %>"
    "Result: 42"
    '((x . nil))))

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

(test runtime-error-inside-expr-points-at-expression
  "A runtime error inside an <%= %> expression body wraps as
   elp-template-error with line/column from *current-template-span*."
  (let ((err (render-error (format nil "hello~%<%= (/ 1 0) %>~%")
                           '())))
    (is (typep err 'elp:elp-template-error))
    (is (= 2 (elp:elp-template-error-line err)))
    ;; Expression content starts immediately after <%= on line 2, at col 4.
    (is (= 4 (elp:elp-template-error-column err)))))

(test runtime-error-column-with-leading-whitespace
  "Column points at the expression content region (just past <%=),
   not at column 1 and not at the <."
  (let ((err (render-error (format nil "line1~%    <%=    (/ 1 0) %>~%")
                           '())))
    (is (typep err 'elp:elp-template-error))
    (is (= 2 (elp:elp-template-error-line err)))
    ;; Line 2 is "    <%=    (/ 1 0) %>"; <%= ends at col 7, content at col 8.
    (is (= 8 (elp:elp-template-error-column err)))))

(test runtime-error-missing-context-key
  "A free variable not present in the context-alist signals
   elp-template-error from the binding prologue."
  (let ((err (render-error "v=<%= deliberately-unbound-template-var %>"
                           '())))
    (is (typep err 'elp:elp-template-error))))

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
      (format nil "before~%after~%")
      '((x . nil))))

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
      "tail"
      '((x . nil))))

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
      (format nil "~%after")
      '((x . nil))))

(test close-trim-on-empty-expr
  "`<%= -%>\\n` (whitespace-only body with trim) skips block AND newline."
  (expect-render
      (format nil "head<%=  -%>~%tail")
      "headtail"))

;;;; Test Group 8d: Open-trim (`<%-`)
;;;; =================================
;;;; `<%-` strips ASCII spaces/tabs immediately preceding the open
;;;; delimiter, back to (but keeping) the prior newline — or to start
;;;; of file if every preceding byte on the line is whitespace.

(test open-trim-strips-leading-indent
  "Indentation before `<%-` on its own line is dropped."
  (expect-render
      (format nil "head~%   <%- (setf x 1) %>tail")
      (format nil "head~%tail")
      '((x . nil))))

(test open-trim-at-start-of-file
  "Leading whitespace before the very first `<%-` (no newline) is dropped."
  (expect-render
      "   <%- (setf x 1) %>after"
      "after"
      '((x . nil))))

(test open-trim-keeps-the-newline-itself
  "Open-trim removes spaces/tabs but preserves the prior newline."
  (expect-render
      (format nil "a~%   <%- (setf x 1) %>b")
      (format nil "a~%b")
      '((x . nil))))

(test open-trim-non-whitespace-on-line-no-strip
  "If anything non-whitespace precedes `<%-` on the same line, no
   stripping happens — the spaces are part of real content."
  (expect-render
      "abc   <%- (setf x 1) %>def"
      "abc   def"
      '((x . nil))))

(test open-trim-on-expr
  "`<%-= ... %>` strips leading indent and emits the value."
  (expect-render
      (format nil "head~%   <%-= 99 %>")
      (format nil "head~%99")))

(test open-trim-on-comment
  "`<%-# ... %>` strips leading indent and emits nothing."
  (expect-render
      (format nil "head~%   <%-# silenced %>tail")
      (format nil "head~%tail")))

(test goal-example-dolist-trim
  "Combined open+close trim on a dolist matches the plan's Goal example."
  (expect-render
      (format nil "<% (dolist (x xs) -%>~%  - <%= x %>~%<%- ) -%>~%")
      (format nil "  - A~%  - B~%  - C~%")
      '((xs . (a b c)))))

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
    (is (equal form '(elp::write-output-range elp::ptr 0 2)))))

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
    (is (equal form '(elp::write-output-range elp::ptr 8 12)))))

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
                          "(elp::write-output-range elp::ptr ~D ~D) "
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

;;;; Test Group 12: Codegen — what does build-template-body produce?
;;;; ================================================================
;;;; Reading the EXPECTED form below is the canonical example of the
;;;; codegen output: write-output-range wrapping each literal text
;;;; span, a let/format wrapper around each <%= %> carrying the byte
;;;; range for runtime error reporting, and the dolist body containing
;;;; the inner forms (the spanning-paren win — the reader appends
;;;; them naturally because it is mid-list when the stream transitions
;;;; through %> ... text ... <%). compile-template wraps this body in
;;;; a (let ((free-var (cdr (assoc 'free-var ctx))) ...) ...) over the
;;;; runtime context-alist; this test pins the body shape only.

(test build-template-body-shape
  "Body sexp for a fixture mixing text, an expression, and a dolist
   spanning blocks. The free symbols (NAME, X) appear bare here;
   compile-template parameterizes them at the lambda layer."
  (let* ((tmpl "Hi <%= name %>!
<% (dolist (x '(1 2 3)) %>* <%= x %>
<% ) %>")
         (path (template-string-to-file tmpl))
         (expected '(progn
                     (elp::write-output-range elp::ptr 0 3)
                     (let ((elp::*current-template-span* '(6 12)))
                       (format t "~A" name))
                     (elp::write-output-range elp::ptr 14 16)
                     (dolist (x '(1 2 3))
                       (elp::write-output-range elp::ptr 42 44)
                       (let ((elp::*current-template-span* '(47 50)))
                         (format t "~A" x))
                       (elp::write-output-range elp::ptr 52 53)))))
    (unwind-protect
         (multiple-value-bind (ptr size fd) (elp::%mmap-open path)
           (unwind-protect
                (let ((generated (elp::build-template-body path ptr size)))
                  (is (equal generated expected)
                      (format nil "Generated body should match.~%Got:~%~S"
                              generated)))
             (elp::%mmap-close ptr size fd)))
      (cleanup-file path))))

;;;; Test Group 13: compile-template (compile once, render many)
;;;; ============================================================
;;;; `(compile-template path)` returns a function of (CTX &OPTIONAL
;;;; STREAM). The same function reused with different contexts must
;;;; produce matching outputs — the win for issue #8. Missing context
;;;; keys signal elp-template-error at the reference site (PROGV
;;;; doesn't bind them, so the body's reference lands an unbound-
;;;; variable error which the existing handler translates).

(defmacro with-compiled-template ((tmpl-var template-string) &body body)
  "Compile TEMPLATE-STRING to a temp file and bind TMPL-VAR to the
   compiled function for the dynamic extent of BODY."
  (let ((path-var (gensym "PATH")))
    `(let ((,path-var (template-string-to-file ,template-string)))
       (unwind-protect
            (let ((,tmpl-var (elp:compile-template ,path-var)))
              ,@body)
         (cleanup-file ,path-var)))))

(defun render-to-string (tmpl ctx)
  "FUNCALL TMPL on CTX and capture output as a string."
  (with-output-to-string (s) (funcall tmpl ctx s)))

(test compile-template-returns-function
  "compile-template returns a callable function."
  (with-compiled-template (tmpl "literal text")
    (is (functionp tmpl))))

(test compile-template-literal-only
  "Literal text renders identically regardless of context."
  (with-compiled-template (tmpl "Hello, World!")
    (is (equal "Hello, World!" (render-to-string tmpl nil)))
    (is (equal "Hello, World!" (render-to-string tmpl '((unused . 42)))))))

(test compile-template-single-expression
  "Single <%= var %> looks up against context at funcall time."
  (with-compiled-template (tmpl "Hi <%= name %>!")
    (is (equal "Hi Alice!" (render-to-string tmpl '((name . "Alice")))))
    (is (equal "Hi Bob!"   (render-to-string tmpl '((name . "Bob")))))))

(test compile-template-reuse-across-contexts
  "Same compiled function, multiple calls, different context-alists.
   This is the win: compile once, render many."
  (with-compiled-template (tmpl "Name: <%= name %>, Age: <%= age %>")
    (is (equal "Name: Alice, Age: 30"
               (render-to-string tmpl '((name . "Alice") (age . 30)))))
    (is (equal "Name: Bob, Age: 7"
               (render-to-string tmpl '((name . "Bob") (age . 7)))))
    (is (equal "Name: Carol, Age: 99"
               (render-to-string tmpl '((name . "Carol") (age . 99)))))))

(test compile-template-spanning-when
  "<% (when ...) %> block spanning multiple tags evaluates per call,
   suppressing or emitting the inner text based on each call's
   context value."
  (with-compiled-template (tmpl "<% (when show %>visible<% ) %>")
    (is (equal "visible" (render-to-string tmpl '((show . t)))))
    (is (equal ""        (render-to-string tmpl '((show . nil)))))))

(test compile-template-missing-context-key-errors
  "Template variables not present in the context-alist signal
   elp-template-error at the reference site — PROGV doesn't bind
   them, so the unbound-variable error fires inside the
   *current-template-span* let, and the handler picks up the right
   line/column. (Note: a globally-bound symbol-value would shadow
   this; the test uses a deliberately unique symbol name.)"
  (let ((path (template-string-to-file
               "v=<%= deliberately-unbound-template-var %>")))
    (unwind-protect
         (let* ((tmpl (elp:compile-template path))
                (err  (handler-case
                          (progn
                            (with-output-to-string (s) (funcall tmpl nil s))
                            nil)
                        (elp:elp-template-error (c) c))))
           (is (typep err 'elp:elp-template-error)))
      (cleanup-file path))))

(test compile-template-empty-file
  "An empty template compiles to a no-op renderer."
  (with-compiled-template (tmpl "")
    (is (equal "" (render-to-string tmpl nil)))))

(test compile-template-via-render-method
  "render specialized on functions delegates to FUNCALL."
  (with-compiled-template (tmpl "Hi <%= name %>!")
    (is (equal "Hi Alice!"
               (with-output-to-string (s)
                 (elp:render tmpl '((name . "Alice")) s))))))

;;;; compile-form / compiled-form

(test compile-form-plain-reference
  "A bare symbol is a single free variable."
  (let ((cf (elp:compile-form 'x)))
    (is (equal '(x) (elp:compiled-form-free-vars cf)))
    (is (= 7 (funcall (elp:compiled-form-fn cf) '((x . 7)))))))

(test compile-form-let-shadowing
  "Lexical bindings inside the form are not free."
  (let ((cf (elp:compile-form '(let ((x 1)) (+ x y)))))
    (is (equal '(y) (elp:compiled-form-free-vars cf)))
    (is (= 11 (funcall (elp:compiled-form-fn cf) '((y . 10)))))))

(test compile-form-let*-sequential
  "LET* binds left-to-right; refs inside the bindings see earlier names."
  (let ((cf (elp:compile-form '(let* ((x 1) (y x)) (+ x y z)))))
    (is (equal '(z) (elp:compiled-form-free-vars cf)))
    (is (= 5 (funcall (elp:compiled-form-fn cf) '((z . 3)))))))

(test compile-form-lambda-params
  "Lambda parameters shadow outer free vars within the lambda body."
  (let ((cf (elp:compile-form '(funcall (lambda (a) (+ a b)) 1))))
    (is (equal '(b) (elp:compiled-form-free-vars cf)))
    (is (= 4 (funcall (elp:compiled-form-fn cf) '((b . 3)))))))

(test compile-form-flet-binds-and-leaks
  "FLET binds the function name; the body's free vars still escape."
  (let ((cf (elp:compile-form '(flet ((f (x) (+ x y))) (f z)))))
    (is (equal '(y z) (elp:compiled-form-free-vars cf)))
    (is (= 12 (funcall (elp:compiled-form-fn cf) '((y . 5) (z . 7)))))))

(test compile-form-dolist-binding
  "DOLIST binds its iteration variable; surrounding refs are free."
  (let ((cf (elp:compile-form '(let ((acc 0))
                                 (dolist (i items acc)
                                   (incf acc (* i factor)))))))
    (is (equal '(factor items) (elp:compiled-form-free-vars cf)))
    (is (= 12 (funcall (elp:compiled-form-fn cf)
                       '((items . (1 2 3)) (factor . 2)))))))

(test compile-form-quoted-symbols-not-free
  "Symbols inside QUOTE forms are data, not references."
  (let ((cf (elp:compile-form '(list 'a 'b c))))
    (is (equal '(c) (elp:compiled-form-free-vars cf)))
    (is (equal '(a b 9) (funcall (elp:compiled-form-fn cf) '((c . 9)))))))

(test compile-form-shadowing-eliminates-free-var
  "An outer let that supplies the only ref means no free vars escape."
  (let ((cf (elp:compile-form '(let ((x 1)) (let ((x 2)) x)))))
    (is (null (elp:compiled-form-free-vars cf)))
    (is (= 2 (funcall (elp:compiled-form-fn cf) nil)))))

(test compile-form-function-position-not-free
  "Function names in operator position are not variable references."
  (let ((cf (elp:compile-form '(+ 1 2))))
    (is (null (elp:compiled-form-free-vars cf)))
    (is (= 3 (funcall (elp:compiled-form-fn cf) nil)))))

(test compile-form-keywords-not-free
  "Keywords are self-evaluating constants, not references."
  (let ((cf (elp:compile-form '(list :tag x))))
    (is (equal '(x) (elp:compiled-form-free-vars cf)))
    (is (equal '(:tag 42) (funcall (elp:compiled-form-fn cf) '((x . 42)))))))

(test compile-form-loop-binds-iteration-var
  "LOOP's FOR clause binds; the source list and accumulator vars are free."
  (let ((cf (elp:compile-form '(loop for x in xs collect (+ x y)))))
    (is (equal '(xs y) (elp:compiled-form-free-vars cf)))
    (is (equal '(11 12 13)
               (funcall (elp:compiled-form-fn cf)
                        '((xs . (1 2 3)) (y . 10)))))))

(test compile-form-source-retained
  "SOURCE round-trips the original form verbatim."
  (let ((form '(if ready (process item) :skipped)))
    (is (equal form (elp:compiled-form-source (elp:compile-form form))))))

(test compile-form-missing-context-key-signals
  "Free vars not present in the alist signal an unbound-variable error."
  (let ((cf (elp:compile-form '(+ x y))))
    (signals unbound-variable
      (funcall (elp:compiled-form-fn cf) '((x . 1))))))

(test compile-form-setf-is-lexical
  "SETF inside the form modifies the local lexical binding only;
   the host image's symbol-value cell is untouched."
  (makunbound 'lexical-setf-target)
  (let ((cf (elp:compile-form '(progn (setf lexical-setf-target 99)
                                      lexical-setf-target))))
    (is (= 99 (funcall (elp:compiled-form-fn cf)
                       '((lexical-setf-target . nil)))))
    (is (not (boundp 'lexical-setf-target)))))

;;;; Run Tests
(defun run-tests ()
  "Run all ELP tests"
  (run! 'generate-suite))
