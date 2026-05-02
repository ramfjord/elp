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
;;;; COMPILE-FORM is the underlying primitive that COMPILE-TEMPLATE's
;;;; codegen mirrors. It's exported and documented, so it gets one
;;;; bare-bones test pinning the public API contract (free-vars
;;;; introspection + funcallable call + source round-trip). The
;;;; behaviors that *do* surface through render — walker-based
;;;; kwarg classification, lexical isolation of SETF — are tested
;;;; under "render" against that interface, since that's how callers
;;;; actually encounter them. We do NOT test CL semantics per se —
;;;; let, let*, dolist, lambda etc. are CL's contract, not ours.
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

(defun render-string (template &rest kwargs)
  "Write TEMPLATE to a temp file, render it with KWARGS as the
   keyword bindings, return the rendered output as a string."
  (let ((path (make-pathname :name "elp-test-temp" :type "elp")))
    (with-open-file (f path :direction :output :if-exists :supersede)
      (write-string template f))
    (unwind-protect
         (with-output-to-string (s)
           (apply #'elp:render path s kwargs))
      (when (probe-file path) (delete-file path)))))

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
;;;; compile-form — the exported primitive
;;;; ============================================================
;;;;
;;;; One test, pinning the public API shape. The walker's
;;;; classification of CL binding forms and the lexical-isolation
;;;; of SETF are tested via render above, since that's the
;;;; interface callers actually use.

(test compile-form-public-contract
  "COMPILE-FORM returns a funcallable instance carrying its
   free-var list and original source. The instance itself is the
   callable — `(funcall cf :x 2 :y 3)`, no accessor wrapper —
   and the same object answers FREE-VARS and SOURCE queries."
  (let* ((form '(+ x y))
         (cf (elp:compile-form form)))
    (is (equal '(x y) (elp:compiled-fn-free-vars cf)))
    (is (= 5 (funcall cf :x 2 :y 3)))
    (is (equal form (elp:compiled-fn-source cf)))))

;;;; ============================================================

(defun run-tests ()
  "Run all ELP tests."
  (run! 'elp-suite))
