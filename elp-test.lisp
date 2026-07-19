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
;;;;     template-body-translator lex states) — exercised end-to-end through
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
  ;; :EXTERNAL-FORMAT is explicit because tests assert on byte offsets
  ;; into the written file. Leaving it to the implementation default
  ;; would make those assertions depend on the host's locale.
  `(uiop:with-temporary-file (:pathname ,path-var :type "elp")
     (with-open-file (f ,path-var :direction :output :if-exists :supersede
                                  :external-format :utf-8)
       (write-string ,content f))
     ,@body))

(defparameter +utf8-template+
  (concatenate 'string "x" (string (code-char 233)) (string (code-char 233))
               "y<%= name %>z")
  "Shared non-ASCII fixture: two e-acutes (2 UTF-8 bytes each) precede
   the tag, so \"name\" begins at CHARACTER index 8 and BYTE offset 10.
   Any assertion that conflates the two units fails on this input and
   passes on an ASCII one — which is precisely how the units confusion
   went unnoticed.")

(defun render-string (template &rest kwargs)
  "Write TEMPLATE to a temp file, render it with KWARGS as the
   keyword bindings, return the rendered output as a string."
  (with-template-file (path template)
    (with-output-to-string (s)
      (apply #'elp:render (elp:filepath-source path) s kwargs))))

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
               ;; FUNCTION-LAMBDA-EXPRESSION on SBCL returns the
               ;; lambda sexp that COMPILE consumed, letting us
               ;; measure printed-form length without re-implementing
               ;; the codegen here.
               (let* ((fn (elp:compile-template (elp:filepath-source path)))
                      (form (function-lambda-expression fn))
                      (*print-pretty* nil))
                 (length (prin1-to-string form))))
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

(test error-position-runtime-string-source
  "Runtime error in a string-source template — exercises the
   handler-bind path without an mmap wrapper. The handler references
   ELP::SOURCE for source-name / source-line+column; string-source
   must bind it just like mmap-source does, or the handler itself
   crashes on unbound-variable instead of producing the wrapped
   condition."
  (let* ((tmpl (elp:compile-template
                (elp:string-source
                 (format nil "first line~%<%= (/ 1 0) %>~%")
                 :name "test-template")))
         (err (handler-case
                  (progn (with-output-to-string (s) (funcall tmpl s)) nil)
                (elp:elp-template-error (c) c))))
    (is (typep err 'elp:elp-template-error))
    (is (equal "test-template" (elp:elp-template-error-file err)))
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

(test compile-template-returns-reusable-fn
  "COMPILE-TEMPLATE returns a function reusable across calls with
   different kwargs — the compile-once / render-many contract. The
   SOURCE is consumed (CLOSE-SOURCE'd) during compilation; the
   returned function is self-contained."
  (let ((path (make-pathname :name "elp-test-reuse" :type "elp")))
    (with-open-file (f path :direction :output :if-exists :supersede)
      (write-string "Hi <%= name %>!" f))
    (unwind-protect
         (let ((tmpl (elp:compile-template (elp:filepath-source path))))
           (is (equal "Hi Alice!"
                      (with-output-to-string (s)
                        (funcall tmpl s :name "Alice"))))
           (is (equal "Hi Bob!"
                      (with-output-to-string (s)
                        (funcall tmpl s :name "Bob")))))
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
               ;; COMPILE-TEMPLATE drives the whole pipeline: drain +
               ;; walk + lambda assembly + COMPILE. SBCL's COMPILE on
               ;; the small assembled lambda is ~1ms (lambda size is
               ;; bounded by code, not source bytes); the time is
               ;; dominated by the drain over the multi-MB fixture.
               (elp:compile-template (elp:filepath-source path)))
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
;;;; translate-closed
;;;;
;;;; Analysis lambda materialization. Driven by either MMAP-SOURCE or
;;;; STRING-SOURCE; the protocol abstracts the difference. Two facets
;;;; we care about: (1) the CLOSED-TEMPLATE-TEXT reads as one
;;;; well-formed (lambda ...) form whose &key list covers exactly the
;;;; free variables in the template, with body chars that appear in
;;;; the same render-shape COMPILE-TEMPLATE produces
;;;; (write-mmap-range / write-string calls + FORMAT wrappers), and
;;;; (2) DOC-OFFSET->SOURCE-BYTE round-trips body chars to source
;;;; bytes, returning NIL for synthesized wrapper / text-emit chars.
;;;; The render path (RENDER / COMPILE-TEMPLATE) is unaffected.

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

(test translate-closed-shape
  "Returned stream drains to (lambda (stream &key …) (let stub-bindings
   (declare …) (progn …))). &key list contains exactly the template's
   free variables; user symbols appear somewhere in the body."
  (with-template-file (p "Hi <%= name %>, age <%= age %>")
    (let* ((s (elp:translate-closed (elp:filepath-source p)))
           (form (elp:template-form s)))
      (is (eq 'lambda (first form)))
      (is (equal (sort (list 'age 'name) #'string< :key #'symbol-name)
                 (sort (copy-list (find-lambda-key-list form))
                       #'string< :key #'symbol-name)))
      (is (tree-find 'name form))
      (is (tree-find 'age form)))))

(test translate-closed-from-string-basic
  "STRING-SOURCE entry point produces a lambda whose &key list reflects
   the string's free variables. Text spans become inlined (write-string
   ...) calls — no on-disk file involved."
  (let* ((s (elp:translate-closed (elp:string-source "hello <%= who %>")))
         (form (elp:template-form s)))
    (is (eq 'lambda (first form)))
    (is (equal '(who) (find-lambda-key-list form)))
    (is (tree-find 'who form))
    (is (tree-find 'write-string form))))

(test translate-closed-spanning-paren
  "Spanning-paren constructs survive as one user form. <% (when active %>
   ON<% ) %> reads as a single (when active …) somewhere in the body,
   with the dangling-paren halves stitched by the same reader trick the
   engine uses."
  (with-template-file (p "<% (when active %>ON<% ) %>")
    (let* ((s (elp:translate-closed (elp:filepath-source p)))
           (form (elp:template-form s))
           (when-form (labels ((walk (x)
                                 (cond ((atom x) nil)
                                       ((and (eq (first x) 'when)
                                             (eq (second x) 'active))
                                        x)
                                       (t (or (walk (car x))
                                              (walk (cdr x)))))))
                        (walk form))))
      (is (consp when-form))
      (is (eq 'when (first when-form)))
      (is (eq 'active (second when-form))))))

(test translate-closed-doc->source-anchored-bytes
  "Body chars whose source is a <% %> or <%= %> block map to their
   original .elp byte. Walk every char of the drained stream and
   verify that anchored chars round-trip to bytes whose template
   content matches the read char.

   Runs on the non-ASCII fixture: MMAP-SOURCE offsets are byte offsets
   and its text decode is latin-1 (one char per byte), so indexing the
   raw byte vector with the mapped offset stays exact even where a
   character spans several bytes. On an ASCII template this assertion
   would hold for the wrong reason."
  (with-template-file (p +utf8-template+)
    (let* ((source-bytes (with-open-file (f p :element-type '(unsigned-byte 8))
                           (let ((buf (make-array (file-length f)
                                                  :element-type '(unsigned-byte 8))))
                             (read-sequence buf f)
                             buf)))
           (tt (elp:translate-closed (elp:filepath-source p)))
           (text (elp:closed-template-text tt))
           (anchored-count 0))
      (loop for pos below (length text)
            for src = (elp:doc-offset->source-offset tt pos)
            when src
              do (is (char= (char text pos) (code-char (aref source-bytes src)))
                     "char ~S at doc-offset ~D → source-byte ~D should match source byte ~A"
                     (char text pos) pos src (code-char (aref source-bytes src)))
                 (incf anchored-count))
      ;; Sanity: at least the 4 letters of "name" between the
      ;; <%= %> delimiters were anchored.
      (is (>= anchored-count 4)))))

(test translate-closed-doc->source-synth-chars-nil
  "Prefix chars (the (lambda …) signature, the (declare …), the (progn)
   opener) and inter-tag synthesized chars all return NIL from
   DOC-OFFSET->SOURCE-BYTE — they have no .elp source byte to point at."
  (with-template-file (p "x<%= name %>y")
    (let* ((tt (elp:translate-closed (elp:filepath-source p)))
           (text (elp:closed-template-text tt))
           (results (loop for pos below (length text)
                          collect (cons pos (elp:doc-offset->source-offset tt pos)))))
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
      (is (null (elp:doc-offset->source-offset tt (1+ (length text))))))))

(test translate-closed-source->doc-round-trip
  "DOC-OFFSET->SOURCE-BYTE and SOURCE-BYTE->DOC-OFFSET form a
   reversible mapping for body chars: forward then reverse returns
   the same doc-offset. The pair is what swank-lsp uses for cursor
   translation in both directions."
  (with-template-file (p "x<%= name %>y")
    (let* ((s (elp:translate-closed (elp:filepath-source p)))
           ;; Pick an anchored doc offset by scanning forward.
           (anchored-doc
            (loop for pos from 0
                  for src = (elp:doc-offset->source-offset s pos)
                  until (integerp src)
                  finally (return pos)))
           (src (elp:doc-offset->source-offset s anchored-doc))
           (round-trip (elp:source-offset->doc-offset s src)))
      (is (integerp src))
      (is (= anchored-doc round-trip)))))

(test source-offset->doc-offset-stops-at-the-end-of-a-run
  "SOURCE-OFFSET->DOC-OFFSET must not invent a document position for
   source that produces no document text.

   Source offsets are not partitioned by the checkpoint sequence the
   way doc offsets are: template literal text past the final anchored
   run has no checkpoint of its own. Extrapolating from the nearest
   preceding anchor without bounding it by that anchor's extent yields
   a plausible-looking offset pointing into synthesized wrapper code.
   DOC-OFFSET->SOURCE-OFFSET is the honest direction, so a result that
   does not map back is the signature of the bug."
  (let* ((content "hello<%= name %>world")
         (tmpl    (elp:translate-open (elp:string-source content)))
         (phantoms '()))
    (dotimes (i (length content))
      (let ((d (elp:source-offset->doc-offset tmpl i)))
        (when (and (integerp d)
                   (null (elp:doc-offset->source-offset tmpl d)))
          (push (list i (char content i) d) phantoms))))
    (is (null phantoms)
        "these source offsets claim a document position that maps back ~
         to NIL (offset char doc-offset): ~S"
        (nreverse phantoms)))
  ;; The anchored region itself must still map, or the bound is too
  ;; tight and we have traded a false positive for a false negative.
  (let* ((content "hello<%= name %>world")
         (tmpl    (elp:translate-open (elp:string-source content)))
         (mapped  (loop for i below (length content)
                        count (integerp (elp:source-offset->doc-offset tmpl i)))))
    (is (>= mapped 4)
        "the source inside <%= name %> must still resolve; only ~D ~
         offsets mapped" mapped)))

(test source-offset->doc-offset-identity-default
  "T methods default to identity — translators that produce an
   offset-equivalent canvas (and consumers that haven't registered a
   real mapping) get a no-op pair for free."
  ;; A stand-in object — any value other than a closed-template uses
  ;; the T-method identity defaults.
  (is (= 42 (elp:doc-offset->source-offset :stub 42)))
  (is (= 17 (elp:source-offset->doc-offset :stub 17))))

(defun %anchor-of-name (source)
  "Source offset the position-map assigns to \"name\" in
   +UTF8-TEMPLATE+, whatever unit SOURCE counts in."
  (let* ((tmpl (elp:translate-open source))
         (doc  (elp:open-template-text tmpl)))
    (loop for d below (- (length doc) 4)
          when (and (string= "name" (subseq doc d (+ d 4)))
                    (integerp (elp:doc-offset->source-offset tmpl d)))
            return (elp:doc-offset->source-offset tmpl d))))

(test position-map-source-offsets-use-each-backends-unit
  "Source offsets are reported in the backing source's own unit, and
   the two backends legitimately differ.

   On +UTF8-TEMPLATE+ the token \"name\" begins at character 8 and byte
   10. STRING-SOURCE is backed by a Lisp string and reports 8;
   MMAP-SOURCE addresses mapped memory and reports 10. Neither is
   wrong — they are answering in different units, which is why
   SOURCE-OFFSET-UNIT exists and why callers must consult it instead
   of assuming.

   This is the pairing an ASCII fixture cannot express: there, 8 and
   10 would both be 8 and the test would pass no matter which unit the
   implementation used."
  (is (eq :character (elp:source-offset-unit (elp:string-source "x"))))
  (is (= 8 (%anchor-of-name (elp:string-source +utf8-template+)))
      "string-source anchors \"name\" at character index 8")
  (with-template-file (p +utf8-template+)
    (is (eq :byte (elp:source-offset-unit (elp:filepath-source p))))
    (is (= 10 (%anchor-of-name (elp:filepath-source p)))
        "mmap-source anchors the same token at byte offset 10")))

(test translate-closed-empty-template
  "Empty .elp yields a minimal lambda that drains and reads as a
   single LAMBDA form without raising."
  (with-template-file (p "")
    (let ((form (elp:template-form (elp:translate-closed (elp:filepath-source p)))))
      (is (eq 'lambda (first form))))))

(test translate-closed-no-free-vars
  "Template with no free variables yields a lambda whose &key list
   has no user-facing entries — just &allow-other-keys."
  (with-template-file (p "plain text only")
    (let* ((s (elp:translate-closed (elp:filepath-source p)))
           (form (elp:template-form s)))
      (is (null (find-lambda-key-list form))))))

;;;; ============================================================
;;;; open-template — the bare emitter form, sits one layer below
;;;; closed-template. Owns: source-wrap + handler-bind + inner
;;;; translated chars; free-vars discovered during construction.
;;;; Does NOT have a callable signature — its TEXT, when READ and
;;;; evaluated, emits to current *standard-output* with free vars
;;;; looked up in the caller's environment.

(test open-template-text-reads-as-one-form
  "open-template-text is a single READable Lisp form. The outer
   shape is the source wrap (a LET for string-source, a
   MULTIPLE-VALUE-BIND for mmap)."
  (let* ((st (elp:translate-open
              (elp:string-source "hi <%= who %>" :name "t.elp")))
         (form (read-from-string (elp:open-template-text st))))
    (is (consp form))
    ;; string-source's wrap is (LET ((ELP::SOURCE …)) …).
    (is (eq 'let (first form)))))

(test open-template-free-vars-matches-template
  "Free-vars discovery surfaces the same symbols the closed-template
   would expose as &key params."
  (let ((st (elp:translate-open
             (elp:string-source "Hi <%= name %>, age <%= age %>"))))
    (is (equal (sort '(name age) #'string< :key #'symbol-name)
               (sort (copy-list (elp:open-template-free-vars st))
                     #'string< :key #'symbol-name)))))

(test open-template-position-map-doc-relative
  "Position-map keys index directly into open-template-text — picking
   a char inside <%= name %> resolves back to a source byte in that
   region of the .elp."
  (let* ((st (elp:translate-open
              (elp:string-source "x<%= name %>y")))
         (text (elp:open-template-text st))
         (anchored-doc
          (loop for pos below (length text)
                when (integerp (elp:doc-offset->source-offset st pos))
                  return pos)))
    (is (integerp anchored-doc))
    (let* ((src (elp:doc-offset->source-offset st anchored-doc))
           (round-trip (elp:source-offset->doc-offset st src)))
      (is (integerp src))
      (is (= anchored-doc round-trip)))))

(test closed-template-wraps-open-template
  "closed-template composes an open-template. Same source → both
   layers see the same free-vars and the inner open-template-text is
   embedded in closed-template-text."
  (let* ((src-text "Hi <%= name %>!")
         (tt (elp:translate-closed (elp:string-source src-text)))
         (inner (elp:closed-template-open tt)))
    (is (typep inner 'elp:open-template))
    (is (equal (elp:open-template-free-vars inner) '(name)))
    (is (search (elp:open-template-text inner)
                (elp:closed-template-text tt))
        "closed-template-text must contain open-template-text verbatim")))

(test template-protocol-works-polymorphically
  "TEMPLATE-TEXT, TEMPLATE-FORM, and the DOC↔SOURCE generics
   dispatch on the shared TEMPLATE protocol class — same call site
   works for both OPEN-TEMPLATE and CLOSED-TEMPLATE."
  (let ((st (elp:translate-open (elp:string-source "hi <%= who %>")))
        (lt (elp:translate-closed (elp:string-source "hi <%= who %>"))))
    (is (typep st 'elp:template))
    (is (typep lt 'elp:template))
    ;; TEMPLATE-TEXT agrees with each layer's specific reader.
    (is (equal (elp:template-text st) (elp:open-template-text st)))
    (is (equal (elp:template-text lt) (elp:closed-template-text lt)))
    ;; TEMPLATE-FORM = (read-from-string (template-text …)).
    (is (consp (elp:template-form st)))
    (is (eq 'lambda (first (elp:template-form lt))))
    ;; DOC↔SOURCE generics work on either subclass.
    (let ((doc-pos (loop for pos below (length (elp:template-text st))
                         when (integerp (elp:doc-offset->source-offset st pos))
                           return pos)))
      (is (integerp doc-pos))
      (is (= doc-pos
             (elp:source-offset->doc-offset
              st (elp:doc-offset->source-offset st doc-pos)))))))

;;;; ============================================================
;;;; Source open/close protocol — pure construction, explicit
;;;; acquire/release. Sources are reusable: build the descriptor
;;;; once, then OPEN-SOURCE / CLOSE-SOURCE around each use.

(test mmap-source-construction-is-pure
  "(MMAP-SOURCE path) builds a descriptor without opening — ptr/size/fd
   stay nil until OPEN-SOURCE runs."
  (with-template-file (p "hello")
    (let ((s (elp:mmap-source p)))
      (is (null (elp::mmap-source-ptr s)))
      (is (null (elp::mmap-source-size s)))
      (is (null (elp::mmap-source-fd s)))
      (elp:close-source s)
      (is (null (elp::mmap-source-ptr s))
          "close-source on an unopened source is a no-op"))))

(test with-open-source-acquires-and-releases
  "WITH-OPEN-SOURCE opens on entry, closes on exit. Inside the body
   the source is usable; afterward it's closed."
  (with-template-file (p "hello world")
    (let ((s (elp:mmap-source p)))
      (elp:with-open-source (src s)
        (is (not (null (elp::mmap-source-ptr src))))
        (is (= 11 (elp::source-length src))))
      (is (null (elp::mmap-source-ptr s))
          "close-source ran on body exit"))))

(test source-is-reusable
  "After a template constructor closes a source, the descriptor is
   still valid for further construction. Build the same template
   twice from one source and render each — both produce the expected
   output."
  (with-template-file (p "Hi <%= name %>")
    (let* ((src (elp:filepath-source p))
           (fn-1 (compile nil (read-from-string
                               (elp:template-text
                                (elp:translate-closed src)))))
           (fn-2 (compile nil (read-from-string
                               (elp:template-text
                                (elp:translate-closed src))))))
      (is (equal "Hi Alice"
                 (with-output-to-string (s) (funcall fn-1 s :name "Alice"))))
      (is (equal "Hi Bob"
                 (with-output-to-string (s) (funcall fn-2 s :name "Bob")))))))

;;;; ============================================================
;;;; SPLICE-TEMPLATE — compile-time splice of an open-template's body
;;;; into the caller's lexical scope. The substitution happens at
;;;; macro-expand time, so the body's free refs resolve against
;;;; whatever lexicals exist at the call site — not against kwargs.

(test splice-template-uses-caller-lexicals
  "splice-template's expansion is part of the caller's lambda, so
   its free refs resolve against the surrounding LET. No kwargs,
   no closed-template wrapper."
  (with-template-file (p "Hi <%= name %>!")
    (let ((name "Ada"))
      (declare (ignorable name))
      (is (equal "Hi Ada!"
                 (with-output-to-string (*standard-output*)
                   (eval `(let ((name ,name))
                            (declare (ignorable name))
                            (elp:splice-template ,(namestring p))))))))))

(test splice-template-resolves-per-iteration-bindings
  "Splicing inside a loop body resolves free refs to each iteration's
   FOR-clause bindings — the use case (loop-services-style)."
  (with-template-file (p "(<%= service %>)")
    (let ((out (with-output-to-string (*standard-output*)
                 (eval `(loop for service in '("radarr" "sonarr" "prowlarr")
                              do (elp:splice-template ,(namestring p)))))))
      (is (equal "(radarr)(sonarr)(prowlarr)" out)))))

;;;; ============================================================

(defun run-tests ()
  "Run all ELP tests."
  (run! 'elp-suite))
