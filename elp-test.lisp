;;;; ELP test suite
;;;;
;;;; Coverage strategy: tests focus on COMPILE-TEMPLATE (the main
;;;; public interface) exercised through RENDER, since that path
;;;; runs the full pipeline — tokenizer + reader, codegen, kwargs
;;;; binding (with supplied-p check inside handler-bind for missing
;;;; keys), and error wrapping. Each test under "render" picks a
;;;; *different elp-specific feature* rather than a different input
;;;; to the same feature.
;;;;
;;;; The walker-driven kwarg classification and the lexical
;;;; isolation of SETF in template bodies are tested through render,
;;;; since render is the only interface callers use. We do NOT test
;;;; CL semantics per se — let, let*, dolist, lambda etc. are CL's
;;;; contract, not ours.
;;;;
;;;; What we DON'T test separately, intentionally:
;;;;   - tokenizer internals (memmem/memchr, byte->line+column,
;;;;     template-stream lex states) — exercised end-to-end through
;;;;     every render test.
;;;;   - tag/syntax permutations beyond one example per feature —
;;;;     each adds maintenance cost without distinct failure modes.
;;;;   - CL behavior of let/loop/lambda/flet — those test CL, not us.

(defpackage :elp-test
  (:use :cl :fiveam :elp)
  (:export :run-tests))

(in-package :elp-test)

(def-suite elp-suite :description "ELP test suite")
(in-suite elp-suite)

;;;; Helpers

(defmacro with-template-file ((path-var content) &body body)
  "Write CONTENT to a fresh .elp file in the system temp directory,
   bind PATH-VAR to its pathname for BODY, and delete the file on
   exit (normal or non-local)."
  `(uiop:with-temporary-file (:pathname ,path-var :type "elp")
     (with-open-file (f ,path-var :direction :output :if-exists :supersede)
       (write-string ,content f))
     ,@body))

(defun render-string (template &rest kwargs)
  "Write TEMPLATE to a temp file, render it with KWARGS as the
   keyword bindings, return the rendered output as a string."
  (with-template-file (path template)
    (with-output-to-string (s)
      (apply #'elp:render path s kwargs))))

(defun render-error (template &rest kwargs)
  "Render TEMPLATE; return the elp-template-error if one was signaled,
   else NIL. Lets tests assert on the wrapped condition + line/col."
  (handler-case (progn (apply #'render-string template kwargs) nil)
    (elp:elp-template-error (c) c)))

;;;; ============================================================
;;;; compile-template / render — the integration path
;;;; ============================================================
;;;;
;;;; Each test exercises a different elp-specific syntax feature.
;;;; Binding semantics (kwargs, missing-key → unbound-variable
;;;; wrapped in elp-template-error) are tested implicitly: every
;;;; test uses the kwargs path, and the missing-kwarg test pins the
;;;; wrapping behavior.

(test render-text-only
  "Plain text passes through unchanged. The simplest end-to-end
   path through the tokenizer and codegen — emits one
   write-output-range call covering the whole source."
  (is (equal "hello world" (render-string "hello world"))))

(test render-expression
  "<%= expr %> outputs the expression's printed form; free
   variables become keyword parameters. Two expressions in one
   template confirm the codegen handles multiple text/expr
   alternations."
  (is (equal "Hi Alice, age 30"
             (render-string "Hi <%= name %>, age <%= age %>"
                            :name "Alice" :age 30))))

(test render-code-block-and-extra-kwargs
  "<% code %> executes without writing to the stream. SETF inside
   mutates the local kwarg binding (the lambda's lexical scope) —
   surrounding text after the block sees the new value. The
   :unused kwarg is dropped silently via &allow-other-keys."
  (is (equal "Result: 42"
             (render-string "<% (setf x 42) %>Result: <%= x %>"
                            :x nil :unused 99))))

(test render-comment
  "<%# … %> blocks are stripped from output, including any
   embedded text — the tokenizer recognizes the # marker and
   discards the entire span."
  (is (equal "AB" (render-string "A<%# arbitrary comment text %>B"))))

(test render-trim-modifiers
  "<%- absorbs ASCII spaces/tabs before the open tag (preserving
   the prior newline); -%> absorbs at most one trailing CR?LF after
   the close. Together they keep generated config files free of
   stray indentation and blank lines from the template's own
   structure."
  (is (equal (format nil "head~%tail")
             (render-string
              (format nil "head~%   <%- (princ \"\") -%>~%tail")))))

(test render-spanning-block
  "An open paren in one <% %> tag and the matching close paren in
   another — the reader walks across intervening text (which
   becomes positional output forms inside the open form). This is
   the load-bearing trick that makes <% (when cond %>...<% ) %>
   read as a single form."
  (is (equal "ON"
             (render-string "<% (when active %>ON<% ) %>" :active t)))
  (is (equal ""
             (render-string "<% (when active %>ON<% ) %>" :active nil))))

(test render-inner-bindings-dont-become-kwargs
  "Names bound *inside* the template body — let, loop FOR
   clauses, lambda parameters, quoted literals, function-position
   symbols — must not surface as required kwargs. Only genuinely
   free references do. Failure mode this catches: the free-vars
   walker mis-classifying an inner binding as free, which would
   force callers to supply junk values for symbols the template
   already binds itself."
  (is (equal "2 4 6 "
             (render-string
              (concatenate
               'string
               "<% (loop for i in items "
               "         for shadowed = (* i factor) "
               "         do (format t \"~A \" shadowed)) %>"
               "<% (let ((local 1)) (when local nil)) %>"
               "<% (mapcar (lambda (x) x) '(quoted-sym)) %>")
              :items '(1 2 3) :factor 2))))

(test render-setf-doesnt-leak-to-host
  "SETF inside <% %> mutates the kwarg's local binding only — the
   host image's symbol-value cell for the same name is untouched.
   The state-isolation contract: a render call never bleeds into
   the surrounding image even when the body reads like it's
   mutating a global."
  (makunbound 'render-leak-target)
  (render-string "<% (setf render-leak-target 99) %>"
                 :render-leak-target nil)
  (is (not (boundp 'render-leak-target))))

(test render-missing-kwarg-wraps-as-template-error
  "A free template variable referenced but not passed signals
   elp-template-error wrapping the underlying unbound-variable.
   Verifies the supplied-p check fires *inside* handler-bind so
   the error gets translated rather than escaping unwrapped."
  (let ((err (render-error "v=<%= some-unset-var %>")))
    (is (typep err 'elp:elp-template-error))
    (is (typep (elp:elp-template-error-original err)
               'unbound-variable))))

;;;; ============================================================
;;;; Codegen size scales with code, not with text
;;;; ============================================================

(test codegen-size-independent-of-text-size
  "Generated code scales with the embedded code, not with the
   volume of literal text around it. Two templates with the same
   single tag — one wrapped in tiny text, the other in a very
   large body of text — produce nearly the same printed-form
   length (the only delta is the digit count of the byte offsets
   stored in WRITE-OUTPUT-RANGE)."
  (with-template-file (tiny " <%= 1 %> ")
    (with-template-file (huge (concatenate 'string
                                           (make-string 50000 :initial-element #\a)
                                           "<%= 1 %>"
                                           (make-string 50000 :initial-element #\b)))
      (flet ((codegen-length (path)
               (let ((*print-pretty* nil))
                 (length (prin1-to-string (elp::%template-lambda-form path)))))
             (within-5% (a b)
               (< (abs (- a b)) (* 0.05 (min a b)))))
        (is (within-5% (codegen-length tiny) (codegen-length huge)))))))

;;;; ============================================================
;;;; Error position reporting
;;;; ============================================================
;;;;
;;;; Position resolution goes through *current-template-span* (set
;;;; per-tag at codegen time, read by the error-translating
;;;; handler via byte->line+column). Two failure modes exercise
;;;; different code paths: runtime error inside an emitted form vs.
;;;; read-time error during template parsing.

(test error-position-runtime
  "Runtime error inside <%= … %> reports the line and the column
   at the start of the expression body (just past <%=)."
  (let ((err (render-error
              (format nil "first line~%<%= (/ 1 0) %>~%"))))
    (is (typep err 'elp:elp-template-error))
    (is (= 2 (elp:elp-template-error-line err)))
    (is (= 4 (elp:elp-template-error-column err)))))

(test error-position-readtime
  "Read-time error (e.g. unbalanced paren in a <% %> block) wraps
   as elp-template-error with a location pointing inside the
   template, not outside. Different code path from runtime errors:
   the reader signals during template parsing rather than during
   the compiled lambda's execution."
  (let ((err (render-error (format nil "ok~%<% (let ((x 1) %>~%"))))
    (is (typep err 'elp:elp-template-error))
    (is (typep (elp:elp-template-error-original err) 'condition))
    (is (>= (elp:elp-template-error-line err) 1))
    (is (>= (elp:elp-template-error-column err) 1))))

;;;; ============================================================
;;;; render dispatch on a precompiled function
;;;; ============================================================

(test render-on-precompiled-function-reuses-it
  "RENDER specialized on a function passes kwargs straight through.
   The compiled template can be reused across calls with different
   kwargs — the compile-once / render-many contract."
  (let ((path (make-pathname :name "elp-test-reuse" :type "elp")))
    (with-open-file (f path :direction :output :if-exists :supersede)
      (write-string "Hi <%= name %>!" f))
    (unwind-protect
         (let ((tmpl (elp:compile-template path)))
           (is (equal "Hi Alice!"
                      (with-output-to-string (s)
                        (elp:render tmpl s :name "Alice"))))
           (is (equal "Hi Bob!"
                      (with-output-to-string (s)
                        (elp:render tmpl s :name "Bob")))))
      (when (probe-file path) (delete-file path)))))

;;;; ============================================================
;;;; read step memory bound
;;;; ============================================================

(test read-step-stays-near-raw-read
  "Read step's wall time stays within a small multiple of just
   slurping the same file's bytes into a Lisp buffer. The baseline
   forces every byte through the page cache into our process — same
   regime as our memmem scans — so the ratio measures ELP overhead
   above a minimum-work read, not disk speed.

   Fixture: tests/fixtures/large.elp — generated by `make
   test-fixtures`. Skipped if absent.

   The 8x bound is wide enough to survive machine differences
   (slower CPU + same disk pushes the ratio up without anything
   actually being broken) and tight enough that a >40% uniform
   slowdown will bust it. The printed ratio is the more useful
   signal for spotting smaller regressions in commit-to-commit
   diffs."
  (let ((path (merge-pathnames "tests/fixtures/large.elp"
                               (or *load-pathname* *default-pathname-defaults*))))
    (if (not (probe-file path))
        (skip "fixture missing — run `make test-fixtures` to generate ~A" path)
    (let* ((file-size (with-open-file (f path) (file-length f)))
           (buf (make-array 65536 :element-type '(unsigned-byte 8))))
      (is (> file-size (* 10 1024 1024))
          "fixture should be at least 10MB to make the ratio meaningful, got ~D" file-size)
      (flet ((slurp ()
               (with-open-file (in path :element-type '(unsigned-byte 8))
                 (loop while (plusp (read-sequence buf in)))))
             (read-step ()
               (elp::%template-lambda-form path))
             (time-it (thunk)
               (let ((start (get-internal-real-time)))
                 (funcall thunk)
                 (/ (* 1000.0 (- (get-internal-real-time) start))
                    internal-time-units-per-second))))
        ;; Warmup: page cache + any first-call lazy work in either path.
        (slurp) (read-step)
        (let* ((baseline-ms (time-it #'slurp))
               (read-ms     (time-it #'read-step))
               (ratio       (/ read-ms (max baseline-ms 0.001))))
          (format t "~%[bench ~,1F MB] read-sequence=~,0F ms  read-step=~,0F ms  ratio=~,2Fx~%"
                  (/ file-size 1024.0 1024.0) baseline-ms read-ms ratio)
          (is (< ratio 8.0)
              "read step should stay within 8x of a raw file read; got ~,2Fx (~,0F ms vs ~,0F ms)"
              ratio read-ms baseline-ms)))))))

;;;; ============================================================
;;;; Embedded-language helpers — code-byte-ranges + extract-code-text.

(test code-byte-ranges-basic-tags
  "<%, <%=, <%# classified correctly; comment ranges excluded."
  (let ((text "<%- (foo) -%>literal<%= bar %><%# secret %>tail"))
    ;; <%- (foo) -%>:  body bytes 3..10 (" (foo) ")
    ;; <%= bar %>:     body bytes 23..28 (" bar ")
    ;; <%# secret %>:  comment, excluded
    (is (equal '((3 . 10) (23 . 28))
               (elp:code-byte-ranges text)))))

(test code-byte-ranges-no-tags-returns-empty
  "Plain text with no <% has no code regions."
  (is (null (elp:code-byte-ranges "hello world")))
  (is (null (elp:code-byte-ranges ""))))

(test code-byte-ranges-multiline
  "Tags spanning newlines: range covers all body bytes including \\n."
  (let* ((text "before
<%- (a)
    (b) -%>
after")
         (ranges (elp:code-byte-ranges text)))
    (is (= 1 (length ranges)))
    (let* ((start (car (first ranges)))
           (end   (cdr (first ranges)))
           (body  (subseq text start end)))
      (is (search "(a)" body))
      (is (search "(b)" body)))))

(test code-byte-ranges-trim-modifiers
  "<%- and -%> trim markers aren't part of the body range."
  (let* ((text "<%- (foo) -%>")
         (ranges (elp:code-byte-ranges text))
         (body  (subseq text (car (first ranges)) (cdr (first ranges)))))
    (is (search "(foo)" body))
    (is (not (search "-" body)))))

(test extract-code-text-byte-equivalence
  "Output is the same length as input; non-code bytes blanked to space."
  (let* ((text "hello<%= bar %>world")
         (out  (elp:extract-code-text text)))
    (is (= (length text) (length out)))
    (is (string= "     " (subseq out 0 5)))      ;; "hello"
    (is (string= "     " (subseq out 15 20)))    ;; "world"
    (is (string= "    bar  " (subseq out 5 14))) ;; <%= bar %> body kept
    ))

(test extract-code-text-preserves-newlines
  "Newlines in the source survive blanking — line numbers don't shift."
  (let* ((text "line1
line2
<%= bar %>")
         (out  (elp:extract-code-text text)))
    (is (char= #\Newline (char out 5)))
    (is (char= #\Newline (char out 11)))
    (is (string= "     " (subseq out 0 5)))    ;; pre-tag blanked
    (is (string= "     " (subseq out 6 11)))))

;;;; ============================================================
;;;; open-template-stream-from-file / -from-string
;;;;
;;;; Analysis lambda form with position map. Two facets we care about:
;;;; (1) the stream's drained text reads as one well-formed (lambda
;;;; ...) form whose &key list covers exactly the free variables in
;;;; the template, with body chars that appear in the same render-
;;;; shape COMPILE-TEMPLATE produces (write-output-range + FORMAT
;;;; wrappers, plus stub bindings for ELP::PTR / SIZE / FD), and (2)
;;;; STREAM-BYTE-POSITION round-trips body chars to source bytes,
;;;; returning NIL for synthesized wrapper / text-emit chars. The
;;;; render path (RENDER / COMPILE-TEMPLATE) is unaffected.

(defun drain-stream (s)
  "Read all chars from S into a string."
  (with-output-to-string (out)
    (loop for c = (read-char s nil :eof)
          until (eq c :eof) do (write-char c out))))

(defun read-stream-form (s)
  "Read one Lisp form from S, returning the sexp."
  (read s))

(defun find-lambda-key-list (form)
  "Given a (lambda (stream &key …) …) form, return the &key params'
   variable names. Handles both the analyze shape (bare symbols) and
   the render shape (((kw var) init supplied-p))."
  (let ((lambda-list (second form)))
    (loop with after-key = nil
          for item in lambda-list
          when (eq item '&allow-other-keys) do (loop-finish)
          when (and after-key (not (member item lambda-list-keywords)))
            collect (cond
                      ((symbolp item) item)
                      ((consp (first item)) (second (first item)))
                      (t (first item)))
          when (eq item '&key) do (setf after-key t))))

(defun tree-find (sym tree)
  "T iff SYM appears anywhere in TREE."
  (cond ((eq sym tree) t)
        ((atom tree) nil)
        (t (or (tree-find sym (car tree)) (tree-find sym (cdr tree))))))

(test open-template-stream-shape
  "Returned stream drains to (lambda (stream &key …) (let stub-bindings
   (declare …) (progn …))). &key list contains exactly the template's
   free variables; user symbols appear somewhere in the body."
  (with-template-file (p "Hi <%= name %>, age <%= age %>")
    (let* ((s (elp:open-template-stream-from-file p))
           (form (read-stream-form s)))
      (is (eq 'lambda (first form)))
      (is (equal (sort '(age name) #'string< :key #'symbol-name)
                 (sort (copy-list (find-lambda-key-list form))
                       #'string< :key #'symbol-name)))
      (is (tree-find 'name form))
      (is (tree-find 'age form)))))

(test open-template-stream-from-string-basic
  "STRING-SOURCE entry point produces a lambda whose &key list reflects
   the string's free variables. Text spans become inlined (write-string
   ...) calls — no on-disk file involved."
  (let* ((s (elp:open-template-stream-from-string "hello <%= who %>"))
         (form (read-stream-form s)))
    (is (eq 'lambda (first form)))
    (is (equal '(who) (find-lambda-key-list form)))
    (is (tree-find 'who form))
    (is (tree-find 'write-string form))))

(test open-template-stream-spanning-paren
  "Spanning-paren constructs survive as one user form. <% (when active %>
   ON<% ) %> reads as a single (when active …) somewhere in the body,
   with the dangling-paren halves stitched by the same reader trick the
   engine uses."
  (with-template-file (p "<% (when active %>ON<% ) %>")
    (let* ((s (elp:open-template-stream-from-file p))
           (form (read-stream-form s)))
      (let ((when-form (cdr (assoc 'when (alexandria:flatten form)))))
        ;; Easier: walk the tree looking for a (when active …) form.
        (let ((found (labels
                         ((walk (x)
                            (cond ((atom x) nil)
                                  ((and (eq (first x) 'when)
                                        (eq (second x) 'active))
                                   x)
                                  (t (or (walk (car x)) (walk (cdr x)))))))
                       (walk form))))
          (declare (ignore when-form))
          (is (consp found))
          (is (eq 'when (first found)))
          (is (eq 'active (second found))))))))

(test open-template-stream-position-map-anchored-bytes
  "Body chars whose source is a <% %> or <%= %> block map to their
   original .elp byte. Walk every char of the drained stream and
   verify that anchored chars round-trip to bytes whose template
   content matches the read char.

   STREAM-BYTE-POSITION's default semantics return the source byte
   the reader is *about to read*, not the one it just read. The test
   tracks the explicit position of each char before consuming it."
  (with-template-file (p "x<%= name %>y")
    (let* ((source-bytes (with-open-file (f p :element-type '(unsigned-byte 8))
                           (let ((buf (make-array (file-length f)
                                                  :element-type '(unsigned-byte 8))))
                             (read-sequence buf f)
                             buf)))
           (s (elp:open-template-stream-from-file p))
           (anchored-count 0))
      (loop for pos from 0
            for src = (elp:stream-byte-position s pos)
            for c = (read-char s nil :eof)
            until (eq c :eof)
            when src
              do (is (char= c (code-char (aref source-bytes src)))
                     "char ~S at reader-pos ~D → source-byte ~D should match source byte ~A"
                     c pos src (code-char (aref source-bytes src)))
                 (incf anchored-count))
      ;; Sanity: at least the 4 letters of "name" between the
      ;; <%= %> delimiters were anchored.
      (is (>= anchored-count 4)))))

(test open-template-stream-position-map-synth-chars-nil
  "Prefix chars (the (lambda …) signature, the (declare …), the (progn)
   opener) and inter-tag synthesized chars all return NIL from
   STREAM-BYTE-POSITION — they have no .elp source byte to point at."
  (with-template-file (p "x<%= name %>y")
    (let* ((s (elp:open-template-stream-from-file p))
           (text-len (length (drain-stream (elp:open-template-stream-from-file p))))
           (results (loop for pos from 0
                          for src = (elp:stream-byte-position s pos)
                          for c = (read-char s nil :eof)
                          until (eq c :eof)
                          collect (cons pos src))))
      ;; The first two chars are `(l` opening the lambda — no source.
      (is (null (cdr (assoc 0 results)))
          "first char (the '(' of lambda) has no source")
      (is (null (cdr (assoc 1 results)))
          "second char (the 'l' of lambda) has no source")
      ;; At least one position lands on a body byte with an integer
      ;; source — the chars from inside <%= name %>.
      (is (find-if (lambda (pair) (integerp (cdr pair))) results)
          "at least one body char has a numeric source byte")
      ;; Positions past EOF return NIL.
      (is (null (elp:stream-byte-position s (1+ text-len)))))))

(test open-template-stream-empty-template
  "Empty .elp yields a minimal lambda that drains and reads as a
   single LAMBDA form without raising."
  (with-template-file (p "")
    (let ((form (read-stream-form (elp:open-template-stream-from-file p))))
      (is (eq 'lambda (first form))))))

(test open-template-stream-no-free-vars
  "Template with no free variables yields a lambda whose &key list
   has no user-facing entries — just &allow-other-keys."
  (with-template-file (p "plain text only")
    (let* ((s (elp:open-template-stream-from-file p))
           (form (read-stream-form s)))
      (is (null (find-lambda-key-list form))))))

;;;; ============================================================

(defun run-tests ()
  "Run all ELP tests."
  (run! 'elp-suite))
