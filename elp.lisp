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
;;;;      function), or OPEN-TEMPLATE-STREAM (analysis lambda stream
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

   Reads the lambda form straight from OPEN-TEMPLATE-STREAM. SOURCE
   is consumed (CLOSE-SOURCE'd) by that call. The compiled lambda is
   self-contained — runtime acquisition (if any) lives in the
   source's SOURCE-WRAP-LAMBDA-BODY."
  (compile nil (read (open-template-stream source))))

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

(declaim (ftype (function (unbound-template-stream) list) %template-free-vars))
(defun %template-free-vars (inner)
  "Discover the template's free variables from a drained
   UNBOUND-TEMPLATE-STREAM. Two internal steps: parse INNER's
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
                (let* ((reader-pos (file-position in))
                       (file-byte  (or (doc-offset->source-byte inner reader-pos)
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

;;;; Reader-driven codegen: unbound-template-stream gray stream
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

(defclass unbound-template-stream (sb-gray:fundamental-character-input-stream)
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
                    %DRAIN-UNBOUND-TEMPLATE-STREAM. NIL until drain
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
    to SOURCE-BYTE in the source. DOC-OFFSET->SOURCE-BYTE uses it to
    translate a reader position back to a source byte; NIL SOURCE-BYTE
    marks synthesized regions with no source backing."))

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
   DOC-OFFSET->SOURCE-BYTE returns NIL for any reader position covered by
   a NIL-anchored checkpoint."
  (let ((top (car (position-map s))))
    (unless (equal top (cons key anchor))
      (push (cons key anchor) (position-map s)))))

;;;; ============================================================
;;;; Reversible doc-offset ↔ source-byte mapping.
;;;;
;;;; Two paired generics. The TEMPLATE-STREAM returned by
;;;; OPEN-TEMPLATE-STREAM specializes both; together they form a
;;;; "reversible mapping" between coordinates in the drained
;;;; document text and bytes in the original source.
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
   "Map DOC-OFFSET (a character index into S's drained text) to the
    corresponding source byte in the .elp file. Returns NIL when
    DOC-OFFSET lies in synthesized (non-source-anchored) territory."))

(defgeneric source-byte->doc-offset (s source-byte)
  (:documentation
   "Map SOURCE-BYTE (an offset into the .elp file) to the
    corresponding character index in S's drained text. Returns NIL
    when SOURCE-BYTE has no representation in the document (e.g.
    bytes inside a comment tag that was stripped)."))

;; T-method identity defaults — byte-equivalent translators inherit
;; these without writing any methods.
(defmethod doc-offset->source-byte ((s t) doc-offset) doc-offset)
(defmethod source-byte->doc-offset  ((s t) source-byte) source-byte)

(defmethod doc-offset->source-byte ((s unbound-template-stream) doc-offset)
  ;; Position-map is sorted descending by doc-offset; the first entry
  ;; with key <= DOC-OFFSET is the chunk containing it. NIL CDR means
  ;; the chunk is synthesized (no source).
  (when-let ((cp (find-if (lambda (c) (<= (car c) doc-offset))
                          (position-map s))))
    (destructuring-bind (cp-doc . cp-src) cp
      (when cp-src (+ cp-src (- doc-offset cp-doc))))))

(defmethod source-byte->doc-offset ((s unbound-template-stream) source-byte)
  ;; Scan for an anchored entry (integer CDR) whose source range
  ;; covers SOURCE-BYTE; the first such entry (newest-first order) is
  ;; the chunk.
  (when-let ((cp (find-if (lambda (c)
                            (and (integerp (cdr c)) (<= (cdr c) source-byte)))
                          (position-map s))))
    (destructuring-bind (cp-doc . cp-src) cp
      (+ cp-doc (- source-byte cp-src)))))

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

(defmethod sb-gray:stream-read-char ((s unbound-template-stream))
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

(defmethod sb-gray:stream-unread-char ((s unbound-template-stream) char)
  (setf (pushback s) char)
  (decf (chars-read s))
  nil)

;;;; ============================================================
;;;; Public stream interface — full lambda form with position map.
;;;;
;;;; OPEN-TEMPLATE-STREAM-FROM-FILE / -FROM-STRING return a character
;;;; input stream whose drained contents are an analysis lambda form
;;;; for the template — same body shape the render path produces,
;;;; wrapped in stub bindings so a static walker / LSP sees every
;;;; symbol as a real lexical or function reference. Bytes produced
;;;; from the user's <% %> / <%= %> blocks are anchored;
;;;; DOC-OFFSET->SOURCE-BYTE translates reader positions into source bytes
;;;; (NIL for synthesized prefix/suffix/text-emit chars).
;;;;
;;;; The stream + position-map carry "translated text plus byte map"
;;;; through one object — a Lisp-LSP can DRAIN the stream into its
;;;; document-text slot and call DOC-OFFSET->SOURCE-BYTE for cursor
;;;; translation, without knowing anything about ELP's internals.
;;;;
;;;; Implementation:
;;;;   1. Accept a SOURCE (see src/source.lisp).
;;;;   2. Drain a TEMPLATE-STREAM over that source to capture
;;;;      (BODY-CHARS, POSITION-MAP).
;;;;   3. Walk the parsed body sexp for free variables.
;;;;   4. Synthesize an analysis lambda prefix (stub bindings for the
;;;;      body's WRITE-OUTPUT-RANGE refs, named &key per free var) and
;;;;      suffix; return a TEMPLATE-STREAM that serves
;;;;      prefix → body → suffix.
;;;;
;;;; The analysis lambda doesn't COMPILE+RUN usefully — the stub
;;;; bindings are NIL, so calling it would error inside
;;;; WRITE-OUTPUT-RANGE. That's intentional: the consumer's job is
;;;; static analysis, not execution.

(defclass template-stream (sb-gray:fundamental-character-input-stream)
  (;; The three computed slots below are populated by
   ;; INITIALIZE-INSTANCE :AFTER from the :SOURCE initarg. Callers
   ;; don't construct the inner stream, don't drive the drain, don't
   ;; see the codegen pipeline — just hand the constructor a SOURCE
   ;; and the resulting stream's drained text is the analysis lambda
   ;; for that template.
   (text
    :reader text
    :documentation "Full lambda text: synthesized prefix (signature,
                    wrapper open, handler-bind, supplied-p checks) +
                    translated inner-template chars (text-emit forms,
                    code blocks, expr blocks) + synthesized suffix
                    (closing parens, cleanup, (values)). Drained
                    linearly by READ-CHAR.")
   (position-map
    :reader position-map
    :documentation "Doc-offset-relative position-map — pre-shifted so
                    keys directly index into TEXT. Anchored entries
                    (integer CDR) cover their chunk; NIL CDR marks
                    synthesized regions (the prefix, inter-block
                    text-emit wrappers, the suffix).")
   (source-name
    :reader source-name
    :documentation "Display name for the source (pathname for files,
                    caller-supplied for strings). Retained for
                    diagnostics.")
   (chars-read
    :initform 0 :accessor chars-read)
   (pushback
    :initform nil :accessor pushback))
  (:documentation
   "Character input stream serving the full analysis (lambda ...) form
    for an ELP template. Constructed from a SOURCE via
    `(make-instance 'template-stream :source source)`; usually via
    OPEN-TEMPLATE-STREAM, which adds CLOSE-SOURCE lifecycle management.
    Drains prefix, then translated-text, then suffix in order.
    DOC-OFFSET->SOURCE-BYTE returns the originating source byte for
    body chars and NIL for wrapper chars."))

(defmethod initialize-instance :after ((s template-stream) &key source)
  "Run the codegen pipeline: drain a fresh UNBOUND-TEMPLATE-STREAM over
   SOURCE, walk for free variables, build the wrapped lambda sexp with
   a body-splice marker, PRIN1 it, split the printed text on the
   marker, and populate S's slots with the resulting prefix /
   translated-text / suffix / position-map / source-name."
  (let* ((inner (%drain-unbound-template-stream
                 (make-instance 'unbound-template-stream :source source)))
         ;; Parse + walk for free variables. Must run while SOURCE is
         ;; still open — reader-error translation needs
         ;; SOURCE-LINE+COLUMN against the original .elp file.
         (free-vars (%template-free-vars inner))
         ;; One gensym per free var; each appears twice in the wrapped
         ;; sexp (the &key declaration and the UNLESS check), and
         ;; *PRINT-CIRCLE* T below makes the two prints share a #N=
         ;; label.
         (supplied-p-vars
          (mapcar (lambda (v)
                    (gensym (format nil "~A-SUPPLIED-P-" v)))
                  free-vars))
         ;; Uninterned sentinel marking where the body chars get
         ;; spliced after PRIN1.
         (marker (make-symbol "ELP-TEMPLATE-BODY-PLACEHOLDER"))
         ;; The full wrapped lambda sexp. Per-source outer wrap (if
         ;; any) comes from SOURCE-WRAP-LAMBDA-BODY. Free-var supplied-p
         ;; checks live inside HANDLER-BIND so missing kwargs surface
         ;; as ELP-TEMPLATE-ERROR with location instead of unwrapped
         ;; UNBOUND-VARIABLE.
         (wrapped-sexp
          `(lambda (stream
                    &key ,@(mapcar (lambda (var supplied-p)
                                     `((,(intern (symbol-name var) :keyword) ,var)
                                       nil
                                       ,supplied-p))
                                   free-vars supplied-p-vars)
                    &allow-other-keys)
             (let ((*standard-output* stream))
               ,(source-wrap-lambda-body
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
                    ,@(mapcar (lambda (var supplied-p)
                                `(unless ,supplied-p
                                   (error 'unbound-variable
                                          :name ',var)))
                              free-vars supplied-p-vars)
                    ,marker)))
             (values)))
         ;; PRIN1 with *PACKAGE*=:CL so ELP-internal symbols print
         ;; package-qualified (they aren't visible from :CL) and CL
         ;; symbols stay bare. Without this, ELP helpers would print
         ;; unqualified and intern in whatever package READ-back ran in.
         (text (let ((*print-pretty* nil)
                     (*print-circle* t)
                     (*package*       (find-package :cl)))
                 (prin1-to-string wrapped-sexp))))
    (multiple-value-bind (prefix suffix)
        (%split-text-on-marker text marker)
      (let ((pl (length prefix)))
        (setf (slot-value s 'text)
              (concatenate 'string prefix (translated-text inner) suffix)
              ;; Shift the inner position-map's body-relative keys to
              ;; doc-relative by adding the prefix length. Now keys
              ;; index directly into TEXT.
              (slot-value s 'position-map)
              (mapcar (lambda (cp)
                        (destructuring-bind (body-pos . source-byte) cp
                          (cons (+ pl body-pos) source-byte)))
                      (position-map inner))
              (slot-value s 'source-name)
              (source-name source))))))

(defmethod sb-gray:stream-read-char ((s template-stream))
  (when-let ((pb (pushback s)))
    (setf (pushback s) nil)
    (incf (chars-read s))
    (return-from sb-gray:stream-read-char pb))
  (let ((p (chars-read s))
        (txt (text s)))
    (cond
      ((>= p (length txt)) :eof)
      (t (incf (chars-read s))
         (char txt p)))))

(defmethod sb-gray:stream-unread-char ((s template-stream) char)
  (setf (pushback s) char)
  (decf (chars-read s))
  nil)

(defmethod doc-offset->source-byte ((s template-stream) doc-offset)
  ;; Position-map keys are already doc-relative (shifted during
  ;; construction). Direct lookup. NIL CDR marks synthesized regions.
  (when-let ((cp (find-if (lambda (c) (<= (car c) doc-offset))
                          (position-map s))))
    (destructuring-bind (cp-doc . cp-src) cp
      (when cp-src (+ cp-src (- doc-offset cp-doc))))))

(defmethod source-byte->doc-offset ((s template-stream) source-byte)
  (when-let ((cp (find-if (lambda (c)
                            (and (integerp (cdr c)) (<= (cdr c) source-byte)))
                          (position-map s))))
    (destructuring-bind (cp-doc . cp-src) cp
      (+ cp-doc (- source-byte cp-src)))))

(defun %drain-unbound-template-stream (inner)
  "Read all characters from INNER (an UNBOUND-TEMPLATE-STREAM) and
   store them in INNER's text slot. Position-map populates as a
   side-effect of the read-char calls. Returns INNER so the caller
   can chain. After this runs, INNER's slots (UTS-TEXT, UTS-POSITION-MAP,
   UTS-SOURCE) form a self-contained record."
  (let ((out (make-string-output-stream)))
    (loop for c = (sb-gray:stream-read-char inner)
          until (eq c :eof)
          do (write-char c out))
    (setf (translated-text inner) (get-output-stream-string out))
    inner))

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

(declaim (ftype (function (t) template-stream) open-template-stream))
(defun open-template-stream (source)
  "Consume SOURCE and return a TEMPLATE-STREAM serving its compiled
   lambda form as a character stream.

   The drained text is the same form COMPILE-TEMPLATE compiles —
   COMPILE-TEMPLATE is literally `(compile nil (read (open-template-stream
   source)))`. The stream is the canonical surface; the compiled
   function is one CL `read` + `compile` away.

   Body chars (from the user's <% %> and <%= %> blocks) carry
   DOC-OFFSET->SOURCE-BYTE anchors to source bytes; wrapper chars
   (synthesized lambda signature, per-source outer wrap,
   handler-bind, key-checks) return NIL.

   Implementation: TEMPLATE-STREAM's INITIALIZE-INSTANCE :AFTER does
   all the codegen work — draining the inner stream, walking for free
   vars, building and splitting the wrapped lambda text. This
   function just owns SOURCE's lifecycle: construct the stream, then
   CLOSE-SOURCE."
  (unwind-protect
       (make-instance 'template-stream :source source)
    (close-source source)))

