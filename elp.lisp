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
;;;; render API, gray-stream parser, codegen, and public stream entry
;;;; points.

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
;;;;      function), or TRANSLATE-TEMPLATE (analysis lambda stream
;;;;      for static walkers / LSPs).
;;;;
;;;; All three consume the source — they call CLOSE-SOURCE after the
;;;; drain step. The compiled lambda RENDER / COMPILE-TEMPLATE produces
;;;; is self-contained; whatever the source's SOURCE-WRAP-LAMBDA-BODY
;;;; emits handles its own runtime acquisition + release, so the
;;;; original source object can be closed.
;;;;
;;;; Compile-once / render-many: COMPILE-TEMPLATE returns a function,
;;;; reusable across calls with different kwargs. The source closes
;;;; after compilation; the returned function is independent of it.

(declaim (ftype (function (t) function) compile-template))
(defun compile-template (source)
  "Compile the template SOURCE and return a function of
   (STREAM &KEY var-1 var-2 … &ALLOW-OTHER-KEYS). The function may
   be reused across calls with different keyword arguments; keys
   absent from a call but referenced by the template signal an
   unbound-variable error at call time, translated to
   ELP-TEMPLATE-ERROR with the correct line/column. Extra keyword
   arguments are silently ignored.

   Reads the lambda form from TRANSLATE-TEMPLATE's materialized text.
   SOURCE is consumed (CLOSE-SOURCE'd) by that call. The compiled
   lambda is self-contained — runtime acquisition (if any) lives in
   the source's SOURCE-WRAP-LAMBDA-BODY."
  (compile nil (read-from-string
                (translated-template-text (translate-template source)))))

(declaim (ftype (function (t stream &rest t) t) render))
(defun render (source stream &rest kwargs)
  "Compile SOURCE and render it to STREAM with KWARGS as the
   template's free-variable bindings.

   Output bytes go to STREAM as they are produced, with no
   intermediate Lisp string. Backend-specific fast paths (e.g.
   zero-copy WRITE(2) for mmap-backed sources against an
   SB-SYS:FD-STREAM destination) are dispatched through the source
   protocol; callers don't pick a path explicitly.

   SOURCE is consumed (CLOSE-SOURCE'd) as part of compilation. For
   compile-once / render-many, call COMPILE-TEMPLATE directly and
   FUNCALL the returned function each time."
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

;;;; Reader-driven codegen: template-body-stream gray stream
;;;;
;;;; A SB-GRAY input stream wrapped around an mmap'd template region.
;;;; Synthesizes Lisp source characters on the fly so that the standard
;;;; reader can walk the template directly and produce the body sexp
;;;; without an intermediate source-string assembly step.
;;;;
;;;; Two layers, separated:
;;;;
;;;;   NEXT-CHUNK — straight-line state machine. Looks at the byte at
;;;;   CURSOR and produces *one* chunk for the next syntactic unit
;;;;   (text-up-to-tag, plain <% %>, expr <%= %>, comment <%# %>, or
;;;;   trailing text), or :EOF when CURSOR has reached SIZE. A chunk
;;;;   is a cons
;;;;     (STRING . ANCHOR-OR-NIL)
;;;;   where STRING is the characters to feed to the reader. ANCHOR
;;;;   is NIL for synthesized wrappers (no meaningful source byte);
;;;;   otherwise it is a cons (CHAR-OFFSET . SOURCE-BYTE) saying
;;;;   "when the reader reaches CHAR-OFFSET into this chunk's string,
;;;;   the corresponding source byte is SOURCE-BYTE." Bodies of
;;;;   <% ... %> and <%= ... %> are materialized once (MMAP-SUBSTRING)
;;;;   and concatenated with their wrappers into the chunk's STRING,
;;;;   so each tag yields exactly one chunk. Comments and
;;;;   whitespace-only <%= %> tags yield no chunk; NEXT-CHUNK loops
;;;;   internally to skip over them.
;;;;
;;;;   STREAM-READ-CHAR — dumb. Drains CHUNK one character at a time;
;;;;   when exhausted, calls NEXT-CHUNK for the next one. The only
;;;;   state transition inside read-char is "this chunk is done,
;;;;   ask NEXT-CHUNK for another."
;;;;
;;;; POSITION-MAP records (READER-POS . MMAP-BYTE) checkpoints. When a
;;;; chunk with a non-nil ANCHOR becomes current, the checkpoint is
;;;; pushed at key=chars-read+CHAR-OFFSET, anchor=SOURCE-BYTE — the
;;;; reader-pos that *will* land on the anchored region.

(defclass template-body-stream (sb-gray:fundamental-character-input-stream)
  ((source          :initarg :source     :reader   source
    :documentation "Backing SOURCE. All byte scanning / substring
                    extraction / text-emit codegen dispatches through
                    the SOURCE protocol.")
   (cursor          :initform 0          :accessor cursor
    :documentation "Next source byte NEXT-CHUNK will look at.")
   (inside-code     :initform nil        :accessor inside-code
    :documentation "T iff CURSOR sits past `<%` and the next NEXT-CHUNK
                    call should parse a tag rather than scan for one.")
   (chunk           :initform nil        :accessor chunk
    :documentation "Currently-draining chunk's string, or NIL when one is needed.")
   (chunk-pos       :initform 0          :accessor chunk-pos
    :documentation "Index of next character to return from CHUNK.")
   (pushback        :initform nil        :accessor pushback)
   (chars-read      :initform 0          :accessor chars-read)
   (position-map    :initform '()        :accessor position-map)
   (translated-text :initform nil        :accessor translated-text
    :documentation "Captured drained character output, populated by
                    %DRAIN-TEMPLATE-BODY-STREAM. NIL until drain
                    runs. Lets the stream act as its own
                    fully-self-contained record of (source, translated
                    chars, position-map) for downstream consumers like
                    %TEMPLATE-FREE-VARS."))
  (:documentation
   "Gray input stream wrapping a SOURCE (mmap- or string-backed) of an
    ELP template. The standard Lisp reader can READ from it directly;
    the stream synthesizes text-emit wrapper forms around literal text
    spans and feeds the bytes inside <% ... %> blocks straight through.

    POSITION-MAP records (READER-POS . SOURCE-BYTE) checkpoints, oldest
    last (push to front). A checkpoint says: at the moment the reader
    has consumed READER-POS chars, the next character will correspond
    to SOURCE-BYTE in the source. NIL SOURCE-BYTE marks synthesized
    regions with no source backing. The map is consumed by
    TRANSLATED-TEMPLATE's INITIALIZE-INSTANCE :AFTER, which shifts
    the keys by the prefix length and stores the result for
    DOC-OFFSET->SOURCE-BYTE / SOURCE-BYTE->DOC-OFFSET lookup."))

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

(defun ts-push-checkpoint (s anchor &optional (key (chars-read s)))
  "Push (KEY . ANCHOR) onto S's POSITION-MAP unless it is already the
   most recent entry. Checkpoints are pushed every time the source of
   the next characters changes (text wrapper, code body, expr body).

   ANCHOR is either an integer source-byte (for chars that originated
   in the .elp file) or NIL (for synthesized chars — text-emit
   wrappers, the expr-prefix FORMAT call, the lambda signature, etc).
   NIL-anchored checkpoints survive into the outer TRANSLATED-TEMPLATE
   so DOC-OFFSET->SOURCE-BYTE can return NIL for those regions."
  (let ((top (car (position-map s))))
    (unless (equal top (cons key anchor))
      (push (cons key anchor) (position-map s)))))

(defun ts-parse-tag-chunk (s)
  "Cursor sits just past the open delimiter (`<%` or `<%-`). Classify
   by the byte at cursor (`=` expr / `#` comment / anything else
   plain code), advance cursor past the closing `%>` (and one
   trailing newline if `-%>`), clear INSIDE-CODE, and return the
   chunk — or NIL for tags that emit nothing.

   The chunk is (STRING . ANCHORS), where ANCHORS is a list of
   (CHUNK-OFFSET . SOURCE-BYTE-OR-NIL) checkpoints in increasing
   offset order. SOURCE-BYTE is an integer for chunk regions whose
   bytes originated in the source; NIL marks synthesized regions
   (text-emit wrappers, the FORMAT prefix on expr blocks, trailing
   delimiter spaces). NIL ANCHORS means the whole chunk is synthesized."
  (let* ((source     (source s))
         (size       (source-length source))
         (after-open (cursor s))
         (first      (and (< after-open size)
                          (source-byte source after-open)))
         (flavor     (cond ((eql first (char-code #\=)) :expr)
                           ((eql first (char-code #\#)) :comment)
                           (t                           :code)))
         (body-start (if (eq flavor :code) after-open (1+ after-open))))
    (setf (cursor s) body-start)
    (let ((body-end (ts-find-code-end s)))
      (setf (inside-code s) nil)
      (ecase flavor
        (:comment nil)
        (:code
         ;; Body bytes followed by a synthesized delimiter space.
         (let* ((body (source-substring source body-start body-end))
                (body-len (length body)))
           (cons (concatenate 'string body " ")
                 `((0 . ,body-start)
                   (,body-len . nil)))))
        (:expr
         ;; Whitespace-only <%= %> silently emits nothing — surfacing
         ;; it would only produce a render-time FORMAT error with no
         ;; obvious link back to the empty body. The FORMAT wrapper
         ;; references elp::*current-template-span* for error
         ;; reporting; the lambda wrapper provides that binding (real
         ;; for render; stub for analysis).
         (let* ((body (source-substring source body-start body-end))
                (body-len (length body)))
           (unless (cl-ppcre:scan *blank-rx* body)
             (let* ((prefix (format nil
                                    "(let ((elp::*current-template-span* '(~D ~D))) (format t \"~~A\" "
                                    body-start body-end))
                    (prefix-len (length prefix)))
               (cons (concatenate 'string prefix body ")) ")
                     `((0 . nil)
                       (,prefix-len . ,body-start)
                       (,(+ prefix-len body-len) . nil)))))))))))

(defun ts-next-chunk (s)
  "Parse the next syntactic unit at (TS-CURSOR S) and return its
   chunk, or :EOF when CURSOR has reached SIZE. Dispatches on
   INSIDE-CODE: T means cursor sits past `<%` and the next unit is a
   tag; NIL means scan forward for the next tag, emitting any
   leading text run as a chunk. Loops internally to skip units that
   emit no chunk (comments, whitespace-only <%= %>, fully-trimmed
   text runs)."
  (let ((source (source s)))
    (loop
      (when (>= (cursor s) (source-length source))
        (return :eof))
      (cond
        ((inside-code s)
         (when-let ((c (ts-parse-tag-chunk s)))
           (return c)))
        (t
         (let* ((text-start (cursor s))
                (text-end   (ts-find-code-start s)))
           (cond
             ((eq text-end :eof)
              ;; No more tags; trailing literal text to EOF.
              (return (cons (synth-text-form source text-start
                                             (source-length source))
                            nil)))
             (t
              (setf (inside-code s) t)
              (when (> text-end text-start)
                (return (cons (synth-text-form source text-start text-end)
                              nil)))))))))))

(defmethod sb-gray:stream-read-char ((s template-body-stream))
  ;; Pushback always wins. Re-incrementing CHARS-READ is correct
  ;; because UNREAD-CHAR decremented it.
  (when-let ((pb (pushback s)))
    (setf (pushback s) nil)
    (incf (chars-read s))
    (return-from sb-gray:stream-read-char pb))
  (loop
    (when (null (chunk s))
      (let ((next (ts-next-chunk s)))
        (when (eq next :eof)
          (return-from sb-gray:stream-read-char :eof))
        (setf (chunk s)     (car next)
              (chunk-pos s) 0)
        ;; The chunk's ANCHORS list enumerates transitions inside the
        ;; chunk between source-anchored and synthesized regions. Each
        ;; entry's CDR is either an integer source-byte or NIL. NIL
        ;; ANCHORS means the whole chunk is synthesized — push one
        ;; barrier at chunk start.
        (let ((anchors (cdr next))
            (base    (chars-read s)))
          (cond
            ((null anchors)
             (ts-push-checkpoint s nil base))
            (t
             (dolist (cp anchors)
               (ts-push-checkpoint s (cdr cp) (+ base (car cp)))))))))
    (let ((str (chunk s))
          (pos (chunk-pos s)))
      (cond
        ((>= pos (length str))
         (setf (chunk s) nil))
        (t
         (incf (chunk-pos s))
         (incf (chars-read s))
         (return-from sb-gray:stream-read-char (char str pos)))))))

(defmethod sb-gray:stream-unread-char ((s template-body-stream) char)
  (setf (pushback s) char)
  (decf (chars-read s))
  nil)

;;;; ============================================================
;;;; Public translation interface — full lambda form with position map.
;;;;
;;;; TRANSLATE-TEMPLATE returns a TRANSLATED-TEMPLATE: a materialized
;;;; analysis lambda form for the template — same body shape the
;;;; render path produces, wrapped so a static walker / LSP sees every
;;;; symbol as a real lexical or function reference. Bytes produced
;;;; from the user's <% %> / <%= %> blocks are anchored;
;;;; DOC-OFFSET->SOURCE-BYTE translates document offsets into source
;;;; bytes (NIL for synthesized prefix/suffix/text-emit chars).
;;;;
;;;; The text + position-map travel together — a Lisp-LSP can paste
;;;; TRANSLATED-TEMPLATE-TEXT into a document buffer and use the
;;;; position-map for cursor translation, without knowing anything
;;;; about ELP's internals.
;;;;
;;;; Implementation:
;;;;   1. Accept a SOURCE (see src/source.lisp).
;;;;   2. Drain a TEMPLATE-BODY-STREAM over that source to materialize
;;;;      the inner body text + per-chunk position-map checkpoints.
;;;;   3. Walk the parsed body sexp for free variables.
;;;;   4. Synthesize an analysis lambda prefix (signature, wrapper
;;;;      open, handler-bind, supplied-p checks) and suffix; splice
;;;;      the inner body between them. Shift the inner position-map
;;;;      keys by the prefix length so they index into the final text.
;;;;
;;;; The analysis lambda doesn't COMPILE+RUN usefully on its own —
;;;; SOURCE-WRAP-LAMBDA-BODY's mmap mvb re-opens the source at render
;;;; time; for static analysis the consumer reads the text, not runs
;;;; it.

;;;; ============================================================
;;;; SEXP-TEMPLATE — the bare emitter form.
;;;;
;;;; A SEXP-TEMPLATE owns the translated template body wrapped in:
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
;;;; LAMBDA-TEMPLATE; sexp-template is the surface a LSP wants
;;;; (no synthetic &key shadowing of project-bound names).

(defclass sexp-template ()
  ((text
    :reader sexp-template-text
    :documentation "PRIN1'd source-wrapped body. READable; evaluating
                    it emits the rendered template to current
                    *standard-output*, contingent on free vars being
                    bound.")
   (position-map
    :reader position-map
    :documentation "Doc-offset-relative position-map — pre-shifted so
                    keys directly index into TEXT.")
   (source-name
    :reader source-name
    :documentation "Display name for the source.")
   (free-vars
    :reader sexp-template-free-vars
    :documentation "List of symbols referenced free in the template
                    body, in stable order (the order LAMBDA-TEMPLATE
                    will turn into &key params)."))
  (:documentation
   "Translated template body: the inner translated chars wrapped in
    the source-specific lexical context (ELP::SOURCE etc.) and
    error-translating handler-bind. Construct via TRANSLATE-SEXP
    (manages source lifecycle) or `(make-instance 'sexp-template
    :source source)` directly (caller closes the source)."))

(defmethod initialize-instance :after ((s sexp-template) &key source)
  "Drain a fresh TEMPLATE-BODY-STREAM over SOURCE, walk for free
   variables, build the source-wrap + handler-bind sexp around a
   body-splice marker, PRIN1 it, splice the inner translated chars
   in, and populate S's slots."
  (let* ((inner (%drain-template-body-stream
                 (make-instance 'template-body-stream :source source)))
         ;; Parse + walk for free variables. Must run while SOURCE is
         ;; still open — reader-error translation needs
         ;; SOURCE-LINE+COLUMN against the original file.
         (free-vars (%template-free-vars inner))
         ;; Uninterned sentinel marking where the inner chars splice.
         (marker (make-symbol "ELP-SEXP-TEMPLATE-BODY-PLACEHOLDER"))
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
         ;; *print-circle* NIL: SEXP-TEMPLATE has no twice-referenced
         ;; gensyms, and the text is concatenated into LAMBDA-TEMPLATE's
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
              free-vars)))))

(declaim (ftype (function (t) sexp-template) translate-sexp))
(defun translate-sexp (source)
  "Consume SOURCE and return a SEXP-TEMPLATE. Mirrors
   TRANSLATE-TEMPLATE's source-lifecycle ownership: closes SOURCE on
   return."
  (unwind-protect
       (make-instance 'sexp-template :source source)
    (close-source source)))

(defclass translated-template ()
  ;; LAMBDA-TEMPLATE composition: holds a SEXP-TEMPLATE and adds the
  ;; callable (LAMBDA (STREAM &KEY …)) wrapper plus supplied-p
  ;; discipline. SEXP-TEMPLATE owns the source-wrap and the
  ;; body-error handler-bind; this layer owns the kwargs interface
  ;; and the missing-kwarg → ELP-TEMPLATE-ERROR translation.
  ((sexp-template
    :reader translated-template-sexp
    :documentation "Inner SEXP-TEMPLATE — the bare emitter form this
                    callable wraps.")
   (text
    :reader translated-template-text
    :documentation "Full lambda text. Pass through READ-FROM-STRING
                    to get the lambda sexp.")
   (position-map
    :reader position-map
    :documentation "Doc-offset-relative position-map — pre-shifted so
                    keys directly index into TEXT.")
   (source-name
    :reader source-name
    :documentation "Display name for the source."))
  (:documentation
   "Materialized analysis lambda for an ELP template, built by
    wrapping a SEXP-TEMPLATE in a callable (LAMBDA (STREAM &KEY …))
    signature. Construct via TRANSLATE-TEMPLATE or `(make-instance
    'translated-template :source source)`."))

(defmethod initialize-instance :after ((s translated-template) &key source)
  "Build the inner SEXP-TEMPLATE, then wrap with the kwarg signature,
   *standard-output* let, and unbound-variable handler-bind that
   covers the supplied-p checks. Splice the sexp-template's text in
   at the body marker; shift its position-map by the prefix length."
  (let* ((inner (make-instance 'sexp-template :source source))
         (free-vars (sexp-template-free-vars inner))
         (name (source-name inner))
         (supplied-p-vars
          (mapcar (lambda (v)
                    (gensym (format nil "~A-SUPPLIED-P-" v)))
                  free-vars))
         (marker (make-symbol "ELP-LAMBDA-TEMPLATE-BODY-PLACEHOLDER"))
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
        (setf (slot-value s 'sexp-template) inner
              (slot-value s 'text)
              (concatenate 'string prefix (sexp-template-text inner) suffix)
              (slot-value s 'position-map)
              (mapcar (lambda (cp)
                        (destructuring-bind (body-pos . source-byte) cp
                          (cons (+ pl body-pos) source-byte)))
                      (position-map inner))
              (slot-value s 'source-name) name)))))

;;;; ============================================================
;;;; Reversible doc-offset ↔ source-byte mapping.
;;;;
;;;; Two paired generics. TRANSLATED-TEMPLATE specializes both;
;;;; together they form a reversible mapping between coordinates in
;;;; the translated text and bytes in the original source.
;;;;
;;;; T methods on both default to identity — translators that produce
;;;; a byte-equivalent canvas (source and document offsets coincide)
;;;; inherit identity behavior for free.
;;;;
;;;; Returns NIL when the input position has no corresponding location
;;;; in the other coordinate system: synthesized chars (no source
;;;; backing) for DOC-OFFSET->SOURCE-BYTE, and source bytes that don't
;;;; appear in the document (e.g. inside a stripped <%# comment %>)
;;;; for SOURCE-BYTE->DOC-OFFSET.

(defgeneric doc-offset->source-byte (s doc-offset)
  (:documentation
   "Map DOC-OFFSET (a character index into S's translated text) to the
    corresponding source byte in the .elp file. Returns NIL when
    DOC-OFFSET lies in synthesized (non-source-anchored) territory."))

(defgeneric source-byte->doc-offset (s source-byte)
  (:documentation
   "Map SOURCE-BYTE (an offset into the .elp file) to the
    corresponding character index in S's translated text. Returns NIL
    when SOURCE-BYTE has no representation in the document (e.g.
    bytes inside a comment tag that was stripped)."))

;; T-method identity defaults — byte-equivalent translators inherit
;; these without writing any methods.
(defmethod doc-offset->source-byte ((s t) doc-offset) doc-offset)
(defmethod source-byte->doc-offset  ((s t) source-byte) source-byte)

(defmethod doc-offset->source-byte ((s translated-template) doc-offset)
  ;; Position-map keys are already doc-relative (shifted during
  ;; construction). Direct lookup. NIL CDR marks synthesized regions.
  (when-let ((cp (find-if (lambda (c) (<= (car c) doc-offset))
                          (position-map s))))
    (destructuring-bind (cp-doc . cp-src) cp
      (when cp-src (+ cp-src (- doc-offset cp-doc))))))

(defmethod doc-offset->source-byte ((s sexp-template) doc-offset)
  ;; Same lookup shape as TRANSLATED-TEMPLATE's method — these collapse
  ;; into one method on the shared protocol class in a later commit.
  (when-let ((cp (find-if (lambda (c) (<= (car c) doc-offset))
                          (position-map s))))
    (destructuring-bind (cp-doc . cp-src) cp
      (when cp-src (+ cp-src (- doc-offset cp-doc))))))

(defmethod source-byte->doc-offset ((s translated-template) source-byte)
  (when-let ((cp (find-if (lambda (c)
                            (and (integerp (cdr c)) (<= (cdr c) source-byte)))
                          (position-map s))))
    (destructuring-bind (cp-doc . cp-src) cp
      (+ cp-doc (- source-byte cp-src)))))

(defmethod source-byte->doc-offset ((s sexp-template) source-byte)
  (when-let ((cp (find-if (lambda (c)
                            (and (integerp (cdr c)) (<= (cdr c) source-byte)))
                          (position-map s))))
    (destructuring-bind (cp-doc . cp-src) cp
      (+ cp-doc (- source-byte cp-src)))))

(defun %drain-template-body-stream (inner)
  "Read all characters from INNER (a TEMPLATE-BODY-STREAM) into its
   TRANSLATED-TEXT slot. Position-map populates as a side-effect of
   the read-char calls. Returns INNER so the caller can chain.
   After this runs, INNER's (SOURCE, TRANSLATED-TEXT, POSITION-MAP)
   slots form a self-contained record of the body translation."
  (let ((out (make-string-output-stream)))
    (loop for c = (sb-gray:stream-read-char inner)
          until (eq c :eof)
          do (write-char c out))
    (setf (translated-text inner) (get-output-stream-string out))
    inner))

(declaim (ftype (function (template-body-stream) list) %template-free-vars))
(defun %template-free-vars (inner)
  "Discover the template's free variables from a drained
   TEMPLATE-BODY-STREAM. Two internal steps: parse INNER's
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
                ;; inner stream is internal and doesn't get the public
                ;; generic. Position-map keys are newest-first, so the
                ;; first entry with key <= reader-pos is the chunk.
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

(declaim (ftype (function (t) translated-template) translate-template))
(defun translate-template (source)
  "Consume SOURCE and return a TRANSLATED-TEMPLATE — the analysis
   lambda's text plus a position-map.

   The text is the same form COMPILE-TEMPLATE compiles —
   COMPILE-TEMPLATE is literally
       (compile nil (read-from-string
                     (translated-template-text (translate-template source))))
   so the translated-template is the canonical surface; the compiled
   function is one READ-FROM-STRING + COMPILE away.

   Body chars (from the user's <% %> and <%= %> blocks) carry
   DOC-OFFSET->SOURCE-BYTE anchors to source bytes; wrapper chars
   (synthesized lambda signature, per-source outer wrap,
   handler-bind, key-checks) return NIL.

   Implementation: TRANSLATED-TEMPLATE's INITIALIZE-INSTANCE :AFTER
   does all the codegen work — draining the inner stream, walking
   for free vars, building and splicing the wrapped lambda text. This
   function just owns SOURCE's lifecycle: construct the object, then
   CLOSE-SOURCE."
  (unwind-protect
       (make-instance 'translated-template :source source)
    (close-source source)))

