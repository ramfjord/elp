;;;; ELP - A template system for Common Lisp
;;;; Inspired by ERB (Embedded Ruby), ELP allows embedding Lisp code in text files.
;;;; Syntax:
;;;;   <%= lisp-expression %>  - outputs the result
;;;;   <% lisp-code %>         - executes code without output
;;;;   <%# comment %>          - comments (removed from output)
;;;;
;;;; Package definition is in src/package.lisp; SOURCE protocol +
;;;; backends (MMAP-SOURCE / STRING-SOURCE) are in src/source.lisp.
;;;; This file holds the template engine itself: free-vars walker,
;;;; render API, tokenizer + translator (TOKEN → TRANSLATION), and
;;;; the OPEN-TEMPLATE / CLOSED-TEMPLATE public surface.

(in-package :elp)

;;;; Error reporting

(define-condition elp-template-error (error)
  ((file     :initarg :file     :reader elp-template-error-file)
   (line     :initarg :line     :reader elp-template-error-line)
   (column   :initarg :column   :reader elp-template-error-column)
   (original :initarg :original :reader elp-template-error-original))
  (:report (lambda (c stream)
             (format stream "Template error at ~A:~D:~D: ~A"
                     (elp-template-error-file c)
                     (elp-template-error-line c)
                     (elp-template-error-column c)
                     (elp-template-error-original c))))
  (:documentation
   "Signaled when reading or rendering a template fails. Wraps the host
    condition (reader error, runtime error inside an embedded form, etc.)
    with a source location resolved against the originating .elp file.

    Errors raised from the engine itself (tokenizer/renderer) and from
    Lisp code embedded in <% ... %> blocks are both translated into this
    condition; the underlying condition is preserved in ORIGINAL."))

(setf (documentation 'elp-template-error-file 'function)
      "Pathname of the .elp source whose render raised the error.")
(setf (documentation 'elp-template-error-line 'function)
      "1-based line number in the .elp source where the error was located.")
(setf (documentation 'elp-template-error-column 'function)
      "1-based column number on the error's line in the .elp source.")
(setf (documentation 'elp-template-error-original 'function)
      "The underlying host condition that ELP-TEMPLATE-ERROR wraps.")

(defvar *current-template-span* nil
  "When non-nil, a list (file-byte-start file-byte-end) identifying the
   byte range in the source template currently being evaluated.")

;;;; Free-variable analysis
;;;;
;;;; HU.DWIM.WALKER classifies every reference in a form's AST as
;;;; lexical / free / special / etc. Filtering on FREE-VARIABLE-
;;;; REFERENCE-FORM gives exactly the symbols not bound by the form
;;;; itself and not proclaimed special. Function-position symbols,
;;;; keywords, T/NIL, quoted forms, and globally-specialed
;;;; variables (DEFVAR/DEFPARAMETER) are all classified under other
;;;; node types and so excluded.

(declaim (ftype (function (t) list) form-free-vars))
(defun form-free-vars (form)
  "Return the sorted list of symbols referenced free in FORM. Free
   means: not lexically bound by FORM, not globally proclaimed
   special, not a function-position symbol, not a keyword or
   self-evaluating constant. Macros are expanded transparently.

   Free references are *expected* at this layer (the whole point is
   to enumerate them), so HU.DWIM.WALKER's UNDEFINED-VARIABLE-
   REFERENCE warnings are muffled here. SBCL's own compile-time
   warnings are unaffected."
  (let* ((ast  (handler-bind ((hu.dwim.walker:undefined-reference
                                #'muffle-warning))
                 (hu.dwim.walker:walk-form form)))
         (refs (hu.dwim.walker:collect-variable-references ast))
         (free (remove-if-not (lambda (r)
                                (typep r 'hu.dwim.walker:free-variable-reference-form))
                              refs)))
    (sort (remove-duplicates (mapcar #'hu.dwim.walker:name-of free))
          #'string< :key #'symbol-name)))

;;;; Public API
;;;;
;;;; Two-step model:
;;;;   1. Build a SOURCE (see src/source.lisp for constructors).
;;;;   2. Hand it to RENDER (one-shot), COMPILE-TEMPLATE (reusable
;;;;      function), or TRANSLATE-CLOSED (analysis lambda stream
;;;;      for static walkers / LSPs).
;;;;
;;;; All three drive the source's OPEN-SOURCE / CLOSE-SOURCE pair
;;;; internally — callers pass a constructed source descriptor and
;;;; don't manage its lifecycle. SOURCE is left in the same un-opened
;;;; state it came in (close-source restores ptr/size/fd to nil for
;;;; mmap-source) and may be reused across multiple calls.
;;;;
;;;; The compiled lambda RENDER / COMPILE-TEMPLATE produces is
;;;; self-contained; whatever the source's SOURCE-WRAP-LAMBDA-BODY
;;;; emits acquires + releases its own resources at render time.
;;;;
;;;; Compile-once / render-many: COMPILE-TEMPLATE returns a function,
;;;; reusable across calls with different kwargs.

(declaim (ftype (function (source) function) compile-template))
(defun compile-template (source)
  "Compile the template SOURCE and return a function of
   (STREAM &KEY var-1 var-2 … &ALLOW-OTHER-KEYS). The function may
   be reused across calls with different keyword arguments; keys
   absent from a call but referenced by the template signal an
   unbound-variable error at call time, translated to
   ELP-TEMPLATE-ERROR with the correct line/column. Extra keyword
   arguments are silently ignored.

   Reads the lambda form from TRANSLATE-CLOSED's materialized text.
   The translator opens SOURCE, drains it, and closes it; SOURCE may
   be reused for further calls. The compiled lambda is self-contained
   — runtime acquisition (if any) lives in the source's
   SOURCE-WRAP-LAMBDA-BODY."
  (compile nil (read-from-string
                (closed-template-text (translate-closed source)))))

(declaim (ftype (function (source stream &rest t) t) render))
(defun render (source stream &rest kwargs)
  "Compile SOURCE and render it to STREAM with KWARGS as the
   template's free-variable bindings.

   Output bytes go to STREAM as they are produced, with no
   intermediate Lisp string. Backend-specific fast paths (e.g.
   zero-copy WRITE(2) for mmap-backed sources against an
   SB-SYS:FD-STREAM destination) are dispatched through the source
   protocol; callers don't pick a path explicitly.

   SOURCE is opened and closed by COMPILE-TEMPLATE; the descriptor
   is reusable afterward. For compile-once / render-many, call
   COMPILE-TEMPLATE directly and FUNCALL the returned function each
   time."
  (apply (compile-template source) stream kwargs))

;;;; Internal Helper Functions

(defun write-mmap-range (mmap-ptr start end &optional (stream *standard-output*))
  "Write bytes [START, END) from MMAP-PTR to STREAM.

   When STREAM is an SBCL fd-stream (e.g. stdout), flushes any buffered output
   then issues a single write(2) syscall directly on the mapped memory — zero
   copy through Lisp.  For other streams (e.g. the string stream used during
   testing) it decodes the UTF-8 bytes from the mapped region and calls
   write-string.

   Referenced by name from the lambda MMAP-SOURCE-EMIT-TEXT-FORM emits, so
   the runtime depends on it being a real defun in the :ELP package."
  (let ((len (- end start))
        (ptr (cffi:inc-pointer mmap-ptr start)))
    (etypecase stream
      (sb-sys:fd-stream
       (finish-output stream)
       (cffi:foreign-funcall "write"
                             :int     (sb-sys:fd-stream-fd stream)
                             :pointer ptr
                             :size    len
                             :long))
      (stream
       (write-string (cffi:foreign-string-to-lisp ptr :count len :encoding :utf-8)
                     stream)))))

;;;; Tokenization + translation: TOKEN, ANCHOR, TRANSLATION, TEMPLATE-BODY-TRANSLATOR
;;;;
;;;; A template body is split into a stream of TOKENs (NEXT-TOKEN). Each
;;;; token covers one syntactic unit of the source: a literal :TEXT run,
;;;; a :CODE / :EXPR / :COMMENT tag body, etc., addressed by a byte
;;;; range in the source.
;;;;
;;;; TRANSLATE-TOKEN turns one token into a TRANSLATION — the Lisp
;;;; source characters that token emits plus the ANCHORs needed to map
;;;; positions in the emitted text back to source bytes. Returns NIL
;;;; for tokens that translate to nothing (comments, whitespace-only
;;;; <%= %>).
;;;;
;;;; %DRAIN-TEMPLATE-BODY walks NEXT-TOKEN→TRANSLATE-TOKEN in a single
;;;; loop, appending each translation's TEXT into the translator's
;;;; TRANSLATED-TEXT and pushing each ANCHOR into POSITION-MAP at
;;;; (CHARS-READ + ANCHOR-OFFSET).

(defstruct (token (:constructor token (kind start end)))
  "One syntactic unit in the source: KIND ∈ {:text :code :expr
   :comment}; START and END are inclusive/exclusive byte offsets of
   the unit's payload (the literal text run, or the tag body excluding
   delimiters). Produced by NEXT-TOKEN; consumed by TRANSLATE-TOKEN."
  (kind  nil :type (member :text :code :expr :comment))
  (start 0   :type unsigned-byte)
  (end   0   :type unsigned-byte))

(defstruct (anchor (:constructor anchor (offset source-byte)))
  "Checkpoint inside a translation's TEXT. At character OFFSET into
   that text, the next character corresponds to SOURCE-BYTE in the
   source — or no source byte (SOURCE-BYTE = NIL) for synthesized
   regions (text-emit wrappers, expr-prefix FORMAT call, trailing
   delimiter spaces)."
  (offset      0 :type unsigned-byte)
  (source-byte 0 :type (or unsigned-byte null)))

(defstruct (translation (:constructor translation (text anchors)))
  "What one TOKEN emits: TEXT is the Lisp source characters, ANCHORS
   is a list of ANCHOR ordered by OFFSET. ANCHORS always starts at
   offset 0 so the translation's source-anchored state at its first
   character is explicit."
  (text    "" :type string)
  (anchors () :type list))

(defclass template-body-translator ()
  ((source          :initarg :source     :reader   source
    :documentation "Backing SOURCE. All byte scanning / substring
                    extraction / text-emit codegen dispatches through
                    the SOURCE protocol.")
   (cursor          :initform 0          :accessor cursor
    :documentation "Next source byte NEXT-TOKEN will look at.")
   (inside-code     :initform nil        :accessor inside-code
    :documentation "T iff CURSOR sits past `<%` and the next NEXT-TOKEN
                    call should parse a tag rather than scan for one.")
   (chars-read      :initform 0          :accessor chars-read
    :documentation "Total characters written into TRANSLATED-TEXT so
                    far. Used as the base offset when pushing
                    position-map checkpoints for the next token.")
   (position-map    :initform '()        :accessor position-map)
   (translated-text :initform nil        :accessor translated-text
    :documentation "Concatenated translated character output, populated
                    by %DRAIN-TEMPLATE-BODY. NIL until drain runs.
                    After drain, (SOURCE, TRANSLATED-TEXT,
                    POSITION-MAP) form a self-contained record for
                    downstream consumers like %TEMPLATE-FREE-VARS."))
  (:documentation
   "State holder for translating an ELP template body into Lisp source
    text. Wraps a SOURCE (mmap- or string-backed) and accumulates
    TRANSLATED-TEXT plus a POSITION-MAP as %DRAIN-TEMPLATE-BODY walks
    it token by token.

    POSITION-MAP is a list of (CHAR-POS . SOURCE-BYTE) cons cells
    (the storage form of ANCHOR after offset-shift), oldest last
    (push to front). The map is consumed by CLOSED-TEMPLATE's
    INITIALIZE-INSTANCE :AFTER, which shifts the keys by the prefix
    length and stores the result for DOC-OFFSET->SOURCE-BYTE /
    SOURCE-BYTE->DOC-OFFSET lookup."))

(defun synth-text-form (source start end)
  "Source string for a literal-text span covering source bytes
   [START, END), expressed as one Lisp form. Delegates to
   SOURCE-EMIT-TEXT-FORM so the form's shape matches what the
   source's SOURCE-WRAP-LAMBDA-BODY will bind."
  (source-emit-text-form source start end))

(defparameter *blank-rx* (cl-ppcre:create-scanner "^\\s*$")
  "Pre-compiled scanner for blank-or-whitespace-only strings; matches
   <%= %> bodies that should be silently skipped.")

(defun ts-advance-cursor (s needle)
  "Search for NEEDLE in the source starting at (TS-CURSOR S). On hit,
   advance CURSOR to the byte immediately past NEEDLE and return the
   match's start byte. On miss, advance CURSOR to source length and
   return NIL. After the call CURSOR sits at the boundary the caller
   would want to resume from."
  (let* ((source (source s))
         (cur    (cursor s))
         (match  (source-search source needle cur)))
    (cond
      (match
       (setf (cursor s) (+ match (length needle)))
       match)
      (t
       (setf (cursor s) (source-length source))
       nil))))

(defun ts-close-trim-p (s close)
  "T when the byte immediately before CLOSE (the offset of `%>`) is
   `-`, i.e. the close delimiter is `-%>`."
  (and close
       (>= close 1)
       (= (source-byte (source s) (1- close)) (char-code #\-))))

(defun ts-open-trim-emit-end (s delim-pos)
  "Walk backward from DELIM-POS over ASCII space/tab bytes. If the walk
   reaches a newline, return the position just past it; if it reaches
   the start of the file through pure whitespace, return 0. Otherwise
   return DELIM-POS (no trim — there is non-whitespace on the line)."
  (let ((source (source s))
        (i (1- delim-pos)))
    (loop while (>= i 0) do
      (let ((b (source-byte source i)))
        (cond
          ((or (= b (char-code #\space)) (= b (char-code #\tab)))
           (decf i))
          ((= b (char-code #\newline))
           (return-from ts-open-trim-emit-end (1+ i)))
          (t
           (return-from ts-open-trim-emit-end delim-pos)))))
    0))

(defun ts-skip-trailing-newline (s)
  "Advance S's CURSOR past at most one `\\r\\n` or `\\n`. Used after a
   close-trim `-%>` to drop the trailing line break."
  (let* ((source (source s))
         (cur  (cursor s))
         (size (source-length source)))
    (cond
      ((and (<= (+ cur 2) size)
            (= (source-byte source cur) (char-code #\return))
            (= (source-byte source (1+ cur)) (char-code #\newline)))
       (setf (cursor s) (+ cur 2)))
      ((and (< cur size)
            (= (source-byte source cur) (char-code #\newline)))
       (setf (cursor s) (1+ cur))))))

(defun ts-find-code-start (s)
  "Advance cursor to just past the next opening delimiter (`<%` or
   `<%-`) and return the byte position where the preceding literal
   text run ends. Open-trim (`<%-`) pulls the end back over leading
   whitespace and the preceding newline, so a blank prefix line is
   dropped from the literal run. Returns :EOF when no further `<%`
   exists; in that case cursor sits at source length."
  (let ((delim-start (ts-advance-cursor s "<%")))
    (cond
      ((null delim-start) :eof)
      (t
       (let* ((source (source s))
              (size   (source-length source))
              (open-trim (and (< (cursor s) size)
                              (= (source-byte source (cursor s))
                                 (char-code #\-)))))
         (when open-trim (incf (cursor s)))
         (if open-trim
             (ts-open-trim-emit-end s delim-start)
             delim-start))))))

(defun ts-find-code-end (s)
  "Advance cursor past the closing delimiter (`%>`, plus one trailing
   newline if `-%>`) and return the byte position where the tag body
   ends. If no closing `%>` exists, cursor goes to source length and
   source length is returned."
  (let ((close (ts-advance-cursor s "%>")))
    (cond
      ((null close) (source-length (source s)))
      ((ts-close-trim-p s close)
       (ts-skip-trailing-newline s)
       (1- close))
      (t close))))

(declaim (ftype (function (template-body-translator anchor unsigned-byte) t)
                push-anchor))
(defun push-anchor (s a base)
  "Push ANCHOR A onto S's POSITION-MAP at key=(BASE + ANCHOR-OFFSET),
   skipped if it would duplicate the most recent entry. Position-map
   entries are stored as (CHAR-POS . SOURCE-BYTE) conses (the
   storage form of an anchor after offset-shift)."
  (let* ((entry (cons (+ base (anchor-offset a)) (anchor-source-byte a)))
         (top   (car (position-map s))))
    (unless (equal top entry)
      (push entry (position-map s)))))

(declaim (ftype (function (template-body-translator) token) parse-tag-token))
(defun parse-tag-token (s)
  "Cursor sits just past the open delimiter (`<%` or `<%-`). Classify
   the tag by the byte at cursor (`=` expr / `#` comment / anything
   else plain code), advance cursor past the closing `%>` (and one
   trailing newline if `-%>`), clear INSIDE-CODE, and return the
   TOKEN covering the body bytes (between delimiters)."
  (let* ((source     (source s))
         (size       (source-length source))
         (after-open (cursor s))
         (first      (and (< after-open size)
                          (source-byte source after-open)))
         (kind       (cond ((eql first (char-code #\=)) :expr)
                           ((eql first (char-code #\#)) :comment)
                           (t                           :code)))
         (body-start (if (eq kind :code) after-open (1+ after-open))))
    (setf (cursor s) body-start)
    (let ((body-end (ts-find-code-end s)))
      (setf (inside-code s) nil)
      (token kind body-start body-end))))

(declaim (ftype (function (template-body-translator) (or token (eql :eof)))
                next-token))
(defun next-token (s)
  "Parse the next syntactic unit at (CURSOR S) and return its TOKEN,
   or :EOF when CURSOR has reached source length. Dispatches on
   INSIDE-CODE: T means cursor sits past `<%` and the next unit is a
   tag; NIL means scan forward for the next tag, emitting any
   leading text run as a :TEXT token first. Empty text runs (the tag
   abuts the cursor, or trim consumed the whole prefix) are skipped
   so the caller never has to filter them — same goes for hitting
   EOF mid-scan with no further tags but no trailing text either."
  (let ((source (source s)))
    (loop
      (when (>= (cursor s) (source-length source))
        (return :eof))
      (cond
        ((inside-code s)
         (return (parse-tag-token s)))
        (t
         (let* ((text-start (cursor s))
                (text-end   (ts-find-code-start s)))
           (cond
             ((eq text-end :eof)
              (when (> (source-length source) text-start)
                (return (token :text text-start (source-length source)))))
             (t
              (setf (inside-code s) t)
              (when (> text-end text-start)
                (return (token :text text-start text-end)))))))))))

(declaim (ftype (function (source token) (or translation null)) translate-token))
(defun translate-token (source tok)
  "Translate one TOKEN to its TRANSLATION, or NIL if it emits nothing.
   :TEXT tokens become a SOURCE-EMIT-TEXT-FORM call (synthesized text,
   one anchor at offset 0 with NIL source-byte). :CODE tokens emit
   the body bytes plus a synthesized trailing space. :EXPR tokens
   wrap the body in a FORMAT call that records the source span in
   ELP::*CURRENT-TEMPLATE-SPAN* for error reporting; whitespace-only
   bodies are silently dropped (a render-time FORMAT error would
   give no obvious link back to the empty body). :COMMENT tokens
   emit nothing."
  (let ((start (token-start tok))
        (end   (token-end tok)))
    (ecase (token-kind tok)
      (:comment nil)
      (:text
       (translation (synth-text-form source start end)
                    (list (anchor 0 nil))))
      (:code
       (let* ((body (source-substring source start end))
              (body-len (length body)))
         (translation (concatenate 'string body " ")
                      (list (anchor 0 start)
                            (anchor body-len nil)))))
      (:expr
       (let* ((body (source-substring source start end))
              (body-len (length body)))
         (unless (cl-ppcre:scan *blank-rx* body)
           (let* ((prefix (format nil
                                  "(let ((elp::*current-template-span* '(~D ~D))) (format t \"~~A\" "
                                  start end))
                  (prefix-len (length prefix)))
             (translation (concatenate 'string prefix body ")) ")
                          (list (anchor 0 nil)
                                (anchor prefix-len start)
                                (anchor (+ prefix-len body-len) nil))))))))))


;;;; ============================================================
;;;; Public translation interface — full lambda form with position map.
;;;;
;;;; Translation surface — two composed layers:
;;;;   OPEN-TEMPLATE   — the body wrapped just enough to be evaluable
;;;;                     (source-wrap + handler-bind). Free vars stay
;;;;                     as bare symbols; the LSP/analysis surface.
;;;;   CLOSED-TEMPLATE — wraps OPEN-TEMPLATE in a callable
;;;;                     (lambda (stream &key …)) signature; the
;;;;                     render surface, COMPILE-TEMPLATE-compatible.
;;;;
;;;; Both share TEMPLATE — text + position-map + source-name + the
;;;; DOC↔SOURCE generics. Body chars (from the user's <% %> / <%= %>
;;;; blocks) carry DOC-OFFSET->SOURCE-BYTE anchors back to source
;;;; bytes; wrapper chars (signature, handler-bind, etc.) return NIL.
;;;; Each layer's text + position-map travel together — a Lisp-LSP
;;;; can paste TEMPLATE-TEXT into a buffer and use the position-map
;;;; for cursor translation, without knowing anything about ELP's
;;;; internals.

;;;; ============================================================
;;;; TEMPLATE — protocol class shared by OPEN-TEMPLATE and
;;;; CLOSED-TEMPLATE. Owns the three slots both layers carry:
;;;; TEXT, POSITION-MAP, SOURCE-NAME. Not intended for direct
;;;; instantiation; the subclasses fill the slots in their own
;;;; INITIALIZE-INSTANCE :AFTER methods.

(defclass template ()
  ((text
    :reader template-text
    :documentation "PRIN1'd generated code, READable. Layer-specific
                    contract:
                      OPEN-TEMPLATE — emits to current
                        *standard-output* when evaluated (given
                        free-var bindings).
                      CLOSED-TEMPLATE — a (lambda (stream &key …))
                        form ready for COMPILE.")
   (position-map
    :reader position-map
    :documentation "Doc-offset-relative position-map — pre-shifted so
                    keys directly index into TEXT.")
   (source-name
    :reader source-name
    :documentation "Display name for the source."))
  (:documentation
   "Protocol class for ELP-generated template forms. Concrete
    subclasses are OPEN-TEMPLATE (bare emitter form, LSP/analysis
    surface) and CLOSED-TEMPLATE (callable wrapper, render surface).
    Shared generics live on this class; layer-specific contract
    lives on the subclasses."))

(defgeneric template-form (template)
  (:documentation
   "READ the template's text and return the resulting Lisp form.
    Convenience over `(read-from-string (template-text template))`
    so callers don't have to know TEXT is the canonical IR.")
  (:method ((s template))
    (read-from-string (template-text s))))

;;;; ============================================================
;;;; OPEN-TEMPLATE — the bare emitter form.
;;;;
;;;; A OPEN-TEMPLATE owns the translated template body wrapped in:
;;;;   1. SOURCE-WRAP-LAMBDA-BODY (binds ELP::SOURCE, plus ELP::PTR
;;;;      etc. for mmap backends so text-emits can dispatch).
;;;;   2. A HANDLER-BIND that translates runtime conditions inside
;;;;      the template body into ELP-TEMPLATE-ERROR using
;;;;      *CURRENT-TEMPLATE-SPAN* for source line/column.
;;;;
;;;; Its TEXT, when READ and evaluated, emits the rendered template
;;;; to whatever *STANDARD-OUTPUT* is currently bound to — given
;;;; bindings for the template's free variables. There is no
;;;; callable signature: free vars are looked up in the calling
;;;; environment. Missing-binding detection lives one layer up at
;;;; CLOSED-TEMPLATE; open-template is the surface a LSP wants
;;;; (no synthetic &key shadowing of project-bound names).

(defclass open-template (template)
  ;; TEXT, POSITION-MAP, SOURCE-NAME inherited from TEMPLATE. Re-list
  ;; TEXT only to add the subclass-specific reader OPEN-TEMPLATE-TEXT
  ;; for callers that want the explicit name.
  ((text :reader open-template-text)
   (free-vars
    :reader open-template-free-vars
    :documentation "List of symbols referenced free in the template
                    body, in stable order (the order CLOSED-TEMPLATE
                    will turn into &key params)."))
  (:documentation
   "Translated template body: the inner translated chars wrapped in
    the source-specific lexical context (ELP::SOURCE etc.) and
    error-translating handler-bind. Construct via `(make-instance
    'open-template :source source)` — the constructor opens SOURCE,
    drains it, and closes it. SOURCE is left in the same un-opened
    state it came in and may be reused for further construction.
    TRANSLATE-OPEN is a one-liner alias."))

(defmethod initialize-instance :after ((s open-template) &key source)
  "Open SOURCE, drain a fresh TEMPLATE-BODY-STREAM over it, walk for
   free variables, build the source-wrap + handler-bind sexp around
   a body-splice marker, PRIN1 it, splice the inner translated chars
   in, and populate S's slots. SOURCE is closed on any exit (normal
   or non-local) — this is the layer that owns the source's
   open/close lifecycle; CLOSED-TEMPLATE's constructor delegates
   here and inherits the guarantee."
  (open-source source)
  (unwind-protect
       (let* ((inner (%drain-template-body
                      (make-instance 'template-body-translator :source source)))
              ;; Parse + walk for free variables. Must run while SOURCE
              ;; is still open — reader-error translation needs
              ;; SOURCE-LINE+COLUMN against the original file.
              (free-vars (%template-free-vars inner))
              ;; Uninterned sentinel marking where the inner chars splice.
              (marker (make-symbol "ELP-OPEN-TEMPLATE-BODY-PLACEHOLDER"))
              (wrapped-sexp
               (source-wrap-lambda-body
                source
                `(handler-bind
                     ((elp-template-error (lambda (c) (error c)))
                      (error
                        (lambda (c)
                          (multiple-value-bind (line col)
                              (if *current-template-span*
                                  (source-line+column elp::source
                                                      (first *current-template-span*))
                                  (values 1 1))
                            (error 'elp-template-error
                                   :file (source-name elp::source)
                                   :line line :column col
                                   :original c)))))
                   ,marker)))
              ;; *print-circle* NIL: OPEN-TEMPLATE has no twice-referenced
              ;; gensyms, and the text is concatenated into CLOSED-TEMPLATE's
              ;; PRIN1 output — sharing labels (#N=) generated here would
              ;; collide with labels generated there.
              (text (let ((*print-pretty* nil)
                          (*print-circle* nil)
                          (*package*       (find-package :cl)))
                      (prin1-to-string wrapped-sexp))))
         (multiple-value-bind (prefix suffix)
             (%split-text-on-marker text marker)
           (let ((pl (length prefix)))
             (setf (slot-value s 'text)
                   (concatenate 'string prefix (translated-text inner) suffix)
                   (slot-value s 'position-map)
                   (mapcar (lambda (cp)
                             (destructuring-bind (body-pos . source-byte) cp
                               (cons (+ pl body-pos) source-byte)))
                           (position-map inner))
                   (slot-value s 'source-name)
                   (source-name source)
                   (slot-value s 'free-vars)
                   free-vars))))
    (close-source source)))

(declaim (ftype (function (source) open-template) translate-open))
(defun translate-open (source)
  "Build an OPEN-TEMPLATE from SOURCE. One-liner alias for
   `(make-instance 'open-template :source source)`. The constructor
   opens SOURCE, drains it, and closes it — SOURCE is left in the
   same un-opened state it came in, and may be reused for further
   template construction."
  (make-instance 'open-template :source source))

(defclass closed-template (template)
  ;; CLOSED-TEMPLATE composition: holds a OPEN-TEMPLATE and adds the
  ;; callable (LAMBDA (STREAM &KEY …)) wrapper plus supplied-p
  ;; discipline. OPEN-TEMPLATE owns the source-wrap and the
  ;; body-error handler-bind; this layer owns the kwargs interface
  ;; and the missing-kwarg → ELP-TEMPLATE-ERROR translation.
  ;;
  ;; TEXT, POSITION-MAP, SOURCE-NAME inherited from TEMPLATE.
  ((text :reader closed-template-text)
   (open-template
    :reader closed-template-open
    :documentation "Inner OPEN-TEMPLATE — the bare emitter form this
                    callable wraps."))
  (:documentation
   "Materialized analysis lambda for an ELP template, built by
    wrapping a OPEN-TEMPLATE in a callable (LAMBDA (STREAM &KEY …))
    signature. Construct via TRANSLATE-CLOSED or `(make-instance
    'closed-template :source source)`."))

(defmethod initialize-instance :after ((s closed-template) &key source)
  "Build the inner OPEN-TEMPLATE, then wrap with the kwarg signature,
   *standard-output* let, and unbound-variable handler-bind that
   covers the supplied-p checks. Splice the open-template's text in
   at the body marker; shift its position-map by the prefix length."
  (let* ((inner (make-instance 'open-template :source source))
         (free-vars (open-template-free-vars inner))
         (name (source-name inner))
         (supplied-p-vars
          (mapcar (lambda (v)
                    (gensym (format nil "~A-SUPPLIED-P-" v)))
                  free-vars))
         (marker (make-symbol "ELP-CLOSED-TEMPLATE-BODY-PLACEHOLDER"))
         ;; Outer wrap: lambda signature + *standard-output* rebind +
         ;; handler-bind that translates supplied-p UNBOUND-VARIABLE
         ;; into ELP-TEMPLATE-ERROR. Missing-kwarg errors come from
         ;; outside any template span, so line/col are 1/1 and the
         ;; source-name is spliced as a literal.
         (wrapped-sexp
          `(lambda (stream
                    &key ,@(mapcar (lambda (var supplied-p)
                                     `((,(intern (symbol-name var) :keyword) ,var)
                                       nil
                                       ,supplied-p))
                                   free-vars supplied-p-vars)
                    &allow-other-keys)
             (let ((*standard-output* stream))
               (handler-bind
                   ((unbound-variable
                      (lambda (c)
                        (error 'elp-template-error
                               :file ,name
                               :line 1 :column 1
                               :original c))))
                 ,@(mapcar (lambda (var supplied-p)
                             `(unless ,supplied-p
                                (error 'unbound-variable :name ',var)))
                           free-vars supplied-p-vars)
                 ,marker))
             (values)))
         (text (let ((*print-pretty* nil)
                     (*print-circle* t)
                     (*package*       (find-package :cl)))
                 (prin1-to-string wrapped-sexp))))
    (multiple-value-bind (prefix suffix)
        (%split-text-on-marker text marker)
      (let ((pl (length prefix)))
        (setf (slot-value s 'open-template) inner
              (slot-value s 'text)
              (concatenate 'string prefix (open-template-text inner) suffix)
              (slot-value s 'position-map)
              (mapcar (lambda (cp)
                        (destructuring-bind (body-pos . source-byte) cp
                          (cons (+ pl body-pos) source-byte)))
                      (position-map inner))
              (slot-value s 'source-name) name)))))

;;;; ============================================================
;;;; Reversible doc-offset ↔ source-offset mapping.
;;;;
;;;; Two paired generics. CLOSED-TEMPLATE specializes both; together
;;;; they form a reversible mapping between coordinates in the
;;;; translated text and positions in the original source.
;;;;
;;;; UNITS. The doc side is always a character index into
;;;; TEMPLATE-TEXT, which is a Lisp string. The source side is in
;;;; whatever unit the backing SOURCE counts in -- bytes for
;;;; MMAP-SOURCE, characters for STRING-SOURCE. Ask the source via
;;;; SOURCE-OFFSET-UNIT; do not assume. The two agree for ASCII and
;;;; diverge by the accumulated UTF-8 overhead after the first
;;;; multi-byte character, so an unchecked assumption here produces
;;;; positions that drift rather than an outright failure.
;;;;
;;;; These generics deliberately do NOT normalize the two backends to
;;;; a common unit. The backends produce structurally different
;;;; documents to begin with (MMAP-SOURCE emits byte-range writes and
;;;; never embeds the template text; STRING-SOURCE inlines it), so
;;;; there is no shared coordinate space to normalize into.
;;;;
;;;; T methods on both default to identity -- translators whose canvas
;;;; is offset-equivalent to their source inherit that for free.
;;;;
;;;; Returns NIL when the input position has no counterpart in the
;;;; other coordinate system: synthesized characters (no source
;;;; backing) for DOC-OFFSET->SOURCE-OFFSET, and source that does not
;;;; appear in the document (e.g. inside a stripped <%# comment %>)
;;;; for SOURCE-OFFSET->DOC-OFFSET.

(defgeneric doc-offset->source-offset (s doc-offset)
  (:documentation
   "Map DOC-OFFSET (a character index into S's translated text) to the
    corresponding position in the source. The result is in the backing
    source's own unit -- see SOURCE-OFFSET-UNIT. Returns NIL when
    DOC-OFFSET lies in synthesized (non-source-anchored) territory."))

(defgeneric source-offset->doc-offset (s source-offset)
  (:documentation
   "Map SOURCE-OFFSET (a position in the source, in that source's own
    unit -- see SOURCE-OFFSET-UNIT) to the corresponding character
    index in S's translated text. Returns NIL when SOURCE-OFFSET has
    no representation in the document (e.g. inside a comment tag that
    was stripped)."))

;; T-method identity defaults -- offset-equivalent translators inherit
;; these without writing any methods.
(defmethod doc-offset->source-offset ((s t) doc-offset) doc-offset)
(defmethod source-offset->doc-offset ((s t) source-offset) source-offset)

(defmethod doc-offset->source-offset ((s template) doc-offset)
  ;; Single method on the protocol class — both OPEN-TEMPLATE and
  ;; CLOSED-TEMPLATE pre-shift their position-map keys to be
  ;; doc-relative at construction, so the lookup is identical.
  ;; NIL CDR marks synthesized regions.
  (when-let ((cp (find-if (lambda (c) (<= (car c) doc-offset))
                          (position-map s))))
    (destructuring-bind (cp-doc . cp-src) cp
      (when cp-src (+ cp-src (- doc-offset cp-doc))))))

(defun %run-extent (map cp)
  "Length of the run CP describes, or NIL if CP is the last checkpoint
   (its run extends to the end of the document).

   Checkpoints record only where a run *starts*. Between two adjacent
   checkpoints the mapping is affine, so a run's length is the gap to
   the next checkpoint's doc key -- and because the mapping is affine,
   that same length measures the run in the source coordinate space
   too. MAP is newest-first (strictly descending doc keys), so the
   successor in doc order is the entry immediately *before* CP."
  (let ((successor nil))
    (dolist (entry map)
      (when (eq entry cp)
        (return (and successor (- (car successor) (car cp)))))
      (setf successor entry))))

(defmethod source-offset->doc-offset ((s template) source-offset)
  ;; Unlike the doc side, source offsets are not partitioned by the
  ;; checkpoint sequence: source that produces no document text (a
  ;; stripped <%# comment %>, template literal past the final anchored
  ;; run) has no checkpoint of its own. Without a bound, the nearest
  ;; preceding anchor would be extrapolated indefinitely and return a
  ;; confident doc offset pointing into unrelated synthesized wrapper.
  ;; Bound the extrapolation by the run's extent instead.
  (let ((map (position-map s)))
    (when-let ((cp (find-if (lambda (c)
                              (and (integerp (cdr c)) (<= (cdr c) source-offset)))
                            map)))
      (destructuring-bind (cp-doc . cp-src) cp
        (let ((extent (%run-extent map cp)))
          (when (or (null extent) (< (- source-offset cp-src) extent))
            (+ cp-doc (- source-offset cp-src))))))))

(defun %drain-template-body (inner)
  "Walk INNER (a TEMPLATE-BODY-TRANSLATOR) NEXT-TOKEN→TRANSLATE-TOKEN
   until :EOF, writing each translation's TEXT into INNER's
   TRANSLATED-TEXT and pushing each ANCHOR into POSITION-MAP at
   (CHARS-READ + ANCHOR-OFFSET). Returns INNER so the caller can
   chain. After this runs, INNER's (SOURCE, TRANSLATED-TEXT,
   POSITION-MAP) slots form a self-contained record of the body
   translation."
  (let ((source (source inner))
        (out    (make-string-output-stream)))
    (loop
      (let ((tok (next-token inner)))
        (when (eq tok :eof) (return))
        (when-let ((tr (translate-token source tok)))
          (let ((base (chars-read inner))
                (text (translation-text tr)))
            (dolist (a (translation-anchors tr))
              (push-anchor inner a base))
            (write-string text out)
            (incf (chars-read inner) (length text))))))
    (setf (translated-text inner) (get-output-stream-string out))
    inner))

(declaim (ftype (function (template-body-translator) list) %template-free-vars))
(defun %template-free-vars (inner)
  "Discover the template's free variables from a drained
   TEMPLATE-BODY-TRANSLATOR. Two internal steps: parse INNER's
   captured text into a body sexp, then walk the sexp in a candidate
   that mirrors the runtime wrapper's lexical scope (so wrapper-
   introduced names ELP::PTR / SIZE / FD / SOURCE aren't classified as
   free; *current-template-span* is a defvar so it's already
   proclaimed special).

   Reader errors during parsing are translated to ELP-TEMPLATE-ERROR
   via INNER's position-map and source — must run while INNER's source
   is still open, since the translator queries SOURCE-LINE+COLUMN."
  (let* ((source (source inner))
         (body-sexp
          (with-input-from-string (in (translated-text inner))
            (handler-case
                (let ((forms '()))
                  (loop for form = (read in nil :eof)
                        until (eq form :eof)
                        do (push form forms))
                  `(progn ,@(nreverse forms)))
              ((or reader-error end-of-file) (c)
                ;; Walk INNER's position-map directly — same lookup
                ;; DOC-OFFSET->SOURCE-BYTE does on the outer, but the
                ;; translator is internal and doesn't get the public
                ;; generic. Position-map keys are newest-first, so the
                ;; first entry with key <= reader-pos is the one we want.
                (let* ((reader-pos (file-position in))
                       (cp (find-if (lambda (c) (<= (car c) reader-pos))
                                    (position-map inner)))
                       (file-byte
                        (or (and cp (cdr cp)
                                 (+ (cdr cp) (- reader-pos (car cp))))
                            0)))
                  (multiple-value-bind (line col)
                      (source-line+column source file-byte)
                    (error 'elp-template-error
                           :file (source-name source) :line line :column col
                           :original c))))))))
    (form-free-vars
     `(lambda (&optional (stream *standard-output*))
        (let ((*standard-output* stream)
              (elp::ptr nil) (elp::size nil) (elp::fd nil)
              (elp::source nil))
          (declare (ignorable elp::ptr elp::size elp::fd elp::source))
          ,body-sexp
          (values))))))

(defun %split-text-on-marker (text marker)
  "TEXT is the PRIN1 of a wrapped lambda sexp; MARKER is the
   uninterned symbol that occupied the body-splice position. Return
   (values PREFIX SUFFIX) — the two halves of TEXT either side of
   the marker's printed form."
  (let* ((marker-text (let ((*print-pretty* nil) (*print-circle* nil))
                        (prin1-to-string marker)))
         (split (search marker-text text)))
    (unless split
      (error "Body marker ~S not found in printed lambda form. ~
              Did *PRINT-PRETTY* or *PRINT-CIRCLE* get bound non-NIL ~
              during PRIN1?" marker-text))
    (values (subseq text 0 split)
            (subseq text (+ split (length marker-text))))))

(declaim (ftype (function (source) closed-template) translate-closed))
(defun translate-closed (source)
  "Build a CLOSED-TEMPLATE from SOURCE — the analysis lambda's text
   plus a position-map. One-liner alias for `(make-instance
   'closed-template :source source)`; the inner OPEN-TEMPLATE
   constructor opens SOURCE, drains it, and closes it. SOURCE is
   reusable across multiple TRANSLATE-CLOSED calls.

   COMPILE-TEMPLATE is literally
       (compile nil (read-from-string
                     (closed-template-text (translate-closed source))))
   — the closed-template is the canonical surface; the compiled
   function is one READ-FROM-STRING + COMPILE away.

   Body chars (from the user's <% %> and <%= %> blocks) carry
   DOC-OFFSET->SOURCE-BYTE anchors to source bytes; wrapper chars
   (synthesized lambda signature, per-source outer wrap,
   handler-bind, key-checks) return NIL."
  (make-instance 'closed-template :source source))

;;;; ============================================================
;;;; Compile-time splicing of open-templates into the caller's scope.

(defmacro splice-template (source-designator)
  "Read an OPEN-TEMPLATE at macro-expand time and return its body sexp
   so the caller's lexical scope binds the template's free variables.
   SOURCE-DESIGNATOR is evaluated at macro-expand time and must yield
   a SOURCE, a pathname, or a path string.

   This is the mechanism for embedding a sub-template inside a context
   that already binds the right symbols — e.g., inside a LOOP whose
   FOR clauses bind the names the sub-template references. Because
   the macro substitutes the body sexp *before* the surrounding code
   is compiled, those references resolve to the caller's lexicals the
   same way they would if you'd typed the body inline.

   Because the source is read at macro-expand time, SOURCE-DESIGNATOR
   must be resolvable then — typically a literal pathname or string.
   The file's contents are baked into the resulting code; at runtime
   the compiled form re-opens the file to read literal bytes
   (mmap-source) or has them inlined as strings (string-source)."
  (let* ((designator (eval source-designator))
         (source (etypecase designator
                   (source designator)
                   (pathname (filepath-source designator))
                   (string (filepath-source (pathname designator))))))
    (template-form (translate-open source))))

