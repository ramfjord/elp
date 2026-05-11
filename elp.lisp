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

(defgeneric render (input stream &rest kwargs)
  (:documentation "Render a template from INPUT to STREAM, passing
   KWARGS through as the template's free-variable bindings.

   Output bytes go to STREAM as they are produced, with no intermediate
   Lisp string. When STREAM is an SB-SYS:FD-STREAM (e.g. the CLI's
   *STANDARD-OUTPUT* in a saved binary), text ranges are written via a
   single WRITE(2) syscall directly on the mmap'd source — zero copy
   through Lisp.

   INPUT is either a pathname (compiled and rendered in one step) or a
   function previously returned by COMPILE-TEMPLATE. KWARGS is the
   plist of `:name value :port value …` entries the template's free
   variables consume; missing required keys signal ELP-TEMPLATE-ERROR
   with line/column information, extras pass through &allow-other-keys
   and are silently dropped.

   Returns no useful value; consumers care about side effects on
   STREAM. Wrap in WITH-OUTPUT-TO-STRING if you want the output as a
   string."))

(defun %template-lambda-form (pathname)
  "Return the (lambda (stream &key …)) sexp that COMPILE-TEMPLATE
   compiles."
  (let ((file-size (with-open-file (f pathname) (file-length f))))
    (when (zerop file-size)
      (return-from %template-lambda-form
        '(lambda (stream &key &allow-other-keys)
          (declare (ignore stream))
          (values)))))
  (let ((source (open-mmap-source pathname)))
    (let ((body (unwind-protect (build-template-body source)
                  (close-mmap-source source))))
      (build-template-lambda source body))))

(defun build-template-lambda (source body)
  "Wrap BODY as a `(lambda (stream &key …))` ready for COMPILE. Each
   free variable in BODY becomes a keyword parameter that errors with
   UNBOUND-VARIABLE when its key is absent at call time.

   The source-specific outer wrapper (mmap mvb + unwind-protect for
   mmap-source; identity for string-source) comes from
   SOURCE-WRAP-LAMBDA-BODY. That wrap binds a fresh runtime SOURCE
   lexical (named ELP::SOURCE) so the handler-bind here can call
   SOURCE-LINE+COLUMN / SOURCE-NAME generically.

   Free vars are determined by walking a candidate form that mirrors
   the wrapper's lexical scope, so wrapper-introduced names aren't
   surfaced as free."
  (let* ((handler-clauses
          `((elp-template-error (lambda (c) (error c)))
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
                         :original c))))))
         ;; Candidate mirrors the wrapper's lexical scope so the
         ;; walker doesn't mis-classify wrapper-bound names. We pass
         ;; BODY in unmodified — wrapper-introduced names are bound by
         ;; SOURCE-WRAP-LAMBDA-BODY's emitted form.
         (candidate
          `(lambda (&optional (stream *standard-output*))
             (let ((*standard-output* stream))
               ,(source-wrap-lambda-body
                 source `(handler-bind ,handler-clauses ,body))
               (values))))
         (free-vars (form-free-vars candidate))
         (supplied-p-vars
          (mapcar (lambda (var)
                    (gensym (format nil "~A-SUPPLIED-P-" var)))
                  free-vars))
         (key-params
          (mapcar (lambda (var supplied-p)
                    `((,(intern (symbol-name var) :keyword) ,var)
                      nil
                      ,supplied-p))
                  free-vars supplied-p-vars))
         ;; Check missing keys *inside* handler-bind so the
         ;; unbound-variable signal becomes an elp-template-error
         ;; with line/column rather than an unwrapped runtime error.
         (key-checks
          (mapcar (lambda (var supplied-p)
                    `(unless ,supplied-p
                       (error 'unbound-variable :name ',var)))
                  free-vars supplied-p-vars))
         ;; HU.DWIM.WALKER:WALK-FORM annotates BODY's cons cells in a
         ;; way that primes SBCL's "unknown variable" warnings. Splice
         ;; a fresh copy into the final form.
         (body-fresh (copy-tree body)))
    `(lambda (stream &key ,@key-params &allow-other-keys)
       (let ((*standard-output* stream))
         ,(source-wrap-lambda-body
           source
           `(handler-bind ,handler-clauses
              ,@key-checks
              ,body-fresh)))
       (values))))

(defun compile-template (pathname)
  "Compile the template at PATHNAME and return a function of
   (STREAM &KEY var-1 var-2 … &ALLOW-OTHER-KEYS). The function may
   be reused across calls with different keyword arguments; keys
   absent from a call but referenced by the template signal an
   unbound-variable error at call time, translated to
   ELP-TEMPLATE-ERROR with the correct line/column. Extra keyword
   arguments are silently ignored, so callers can pass a
   comprehensive bag of bindings and let each template pick the
   subset it needs."
  (compile nil (%template-lambda-form pathname)))

(defmethod render ((fn function) stream &rest kwargs)
  (apply fn stream kwargs))

(defmethod render ((pathname pathname) stream &rest kwargs)
  (apply (compile-template pathname) stream kwargs))

;;;; Internal Helper Functions

(defun write-output-range (mmap-ptr start end &optional (stream *standard-output*))
  "Write bytes [START, END) from MMAP-PTR to STREAM.

   When STREAM is an SBCL fd-stream (e.g. stdout), flushes any buffered output
   then issues a single write(2) syscall directly on the mapped memory — zero
   copy through Lisp.  For other streams (e.g. the string stream used during
   testing) it decodes the UTF-8 bytes from the mapped region and calls
   write-string."
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

(defun build-template-body (source)
  "Read the template SOURCE through a TEMPLATE-STREAM and return the
   inner body sexp `(progn ,@forms)`. Reader errors are translated
   into ELP-TEMPLATE-ERROR via the stream's POSITION-MAP."
  (let* ((stream (make-instance 'template-stream :source source))
         (forms  '()))
    (handler-case
        (loop for form = (read stream nil :eof)
              until (eq form :eof)
              do (push form forms))
      ((or reader-error end-of-file) (c)
        (translate-read-error c source stream)))
    `(progn ,@(nreverse forms))))

(defun translate-read-error (condition source stream)
  "Translate a reader-error raised while reading STREAM into an
   ELP-TEMPLATE-ERROR pointing at the source byte that produced the
   offending reader position. Falls back to byte 0 when the stream
   has not yet reached any checkpoint."
  (let* ((reader-pos (ts-chars-read stream))
         (file-byte  (or (stream-byte-position stream reader-pos) 0)))
    (multiple-value-bind (line col) (source-line+column source file-byte)
      (error 'elp-template-error
             :file (source-name source) :line line :column col
             :original condition))))

;;;; Reader-driven codegen: template-stream gray stream
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

(defclass template-stream (sb-gray:fundamental-character-input-stream)
  ((source       :initarg :source     :reader   ts-source
    :documentation "Backing source — an MMAP-SOURCE or STRING-SOURCE.
                    All byte scanning / substring extraction / text-emit
                    codegen dispatches through the SOURCE protocol.")
   (cursor       :initform 0          :accessor ts-cursor
    :documentation "Next source byte NEXT-CHUNK will look at.")
   (inside-code  :initform nil        :accessor ts-inside-code
    :documentation "T iff CURSOR sits past `<%` and the next NEXT-CHUNK
                    call should parse a tag rather than scan for one.")
   (chunk        :initform nil        :accessor ts-chunk
    :documentation "Currently-draining chunk's string, or NIL when one is needed.")
   (chunk-pos    :initform 0          :accessor ts-chunk-pos
    :documentation "Index of next character to return from CHUNK.")
   (pushback     :initform nil        :accessor ts-pushback)
   (chars-read   :initform 0          :accessor ts-chars-read)
   (position-map :initform '()        :accessor ts-position-map))
  (:documentation
   "Gray input stream wrapping a SOURCE (mmap- or string-backed) of an
    ELP template. The standard Lisp reader can READ from it directly;
    the stream synthesizes text-emit wrapper forms around literal text
    spans and feeds the bytes inside <% ... %> blocks straight through.

    POSITION-MAP records (READER-POS . SOURCE-BYTE) checkpoints, oldest
    last (push to front). A checkpoint says: at the moment the reader
    has consumed READER-POS chars, the next character will correspond
    to SOURCE-BYTE in the source. STREAM-BYTE-POSITION uses it to
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
  (let* ((source (ts-source s))
         (cur    (ts-cursor s))
         (match  (source-search source needle cur)))
    (cond
      (match
       (setf (ts-cursor s) (+ match (length needle)))
       match)
      (t
       (setf (ts-cursor s) (source-length source))
       nil))))

(defun ts-close-trim-p (s close)
  "T when the byte immediately before CLOSE (the offset of `%>`) is
   `-`, i.e. the close delimiter is `-%>`."
  (and close
       (>= close 1)
       (= (source-byte (ts-source s) (1- close)) (char-code #\-))))

(defun ts-open-trim-emit-end (s delim-pos)
  "Walk backward from DELIM-POS over ASCII space/tab bytes. If the walk
   reaches a newline, return the position just past it; if it reaches
   the start of the file through pure whitespace, return 0. Otherwise
   return DELIM-POS (no trim — there is non-whitespace on the line)."
  (let ((source (ts-source s))
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
  (let* ((source (ts-source s))
         (cur  (ts-cursor s))
         (size (source-length source)))
    (cond
      ((and (<= (+ cur 2) size)
            (= (source-byte source cur) (char-code #\return))
            (= (source-byte source (1+ cur)) (char-code #\newline)))
       (setf (ts-cursor s) (+ cur 2)))
      ((and (< cur size)
            (= (source-byte source cur) (char-code #\newline)))
       (setf (ts-cursor s) (1+ cur))))))

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
       (let* ((source (ts-source s))
              (size   (source-length source))
              (open-trim (and (< (ts-cursor s) size)
                              (= (source-byte source (ts-cursor s))
                                 (char-code #\-)))))
         (when open-trim (incf (ts-cursor s)))
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
      ((null close) (source-length (ts-source s)))
      ((ts-close-trim-p s close)
       (ts-skip-trailing-newline s)
       (1- close))
      (t close))))

(defun ts-push-checkpoint (s anchor &optional (key (ts-chars-read s)))
  "Push (KEY . ANCHOR) onto S's POSITION-MAP unless it is already the
   most recent entry. Checkpoints are pushed every time the source of
   the next characters changes (text wrapper, code body, expr body).

   ANCHOR is either an integer source-byte (for chars that originated
   in the .elp file) or NIL (for synthesized chars — text-emit
   wrappers, the expr-prefix FORMAT call, the lambda signature, etc).
   STREAM-BYTE-POSITION returns NIL for any reader position covered by
   a NIL-anchored checkpoint."
  (let ((top (car (ts-position-map s))))
    (unless (equal top (cons key anchor))
      (push (cons key anchor) (ts-position-map s)))))

(defgeneric stream-byte-position (s &optional reader-pos)
  (:documentation
   "Map READER-POS (a character index into S's output, defaulting to
    S's current CHARS-READ) to the corresponding source byte in the
    underlying .elp file. Returns NIL when READER-POS lies in
    synthesized (non-source-anchored) territory — wrapper chunks,
    text-emit forms, blank-stripped expressions, etc."))

(defmethod stream-byte-position ((s template-stream)
                                 &optional (reader-pos (ts-chars-read s)))
  ;; POSITION-MAP is pushed newest-first with monotonically increasing
  ;; keys, so it is sorted descending — the first entry with key <=
  ;; READER-POS is the largest such entry.
  (when-let ((checkpoint (find-if (lambda (c) (<= (car c) reader-pos))
                                  (ts-position-map s))))
    (destructuring-bind (cp-reader-pos . cp-mmap-byte) checkpoint
      (when cp-mmap-byte
        (+ cp-mmap-byte (- reader-pos cp-reader-pos))))))

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
  (let* ((source     (ts-source s))
         (size       (source-length source))
         (after-open (ts-cursor s))
         (first      (and (< after-open size)
                          (source-byte source after-open)))
         (flavor     (cond ((eql first (char-code #\=)) :expr)
                           ((eql first (char-code #\#)) :comment)
                           (t                           :code)))
         (body-start (if (eq flavor :code) after-open (1+ after-open))))
    (setf (ts-cursor s) body-start)
    (let ((body-end (ts-find-code-end s)))
      (setf (ts-inside-code s) nil)
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
  (let ((source (ts-source s)))
    (loop
      (when (>= (ts-cursor s) (source-length source))
        (return :eof))
      (cond
        ((ts-inside-code s)
         (when-let ((c (ts-parse-tag-chunk s)))
           (return c)))
        (t
         (let* ((text-start (ts-cursor s))
                (text-end   (ts-find-code-start s)))
           (cond
             ((eq text-end :eof)
              ;; No more tags; trailing literal text to EOF.
              (return (cons (synth-text-form source text-start
                                             (source-length source))
                            nil)))
             (t
              (setf (ts-inside-code s) t)
              (when (> text-end text-start)
                (return (cons (synth-text-form source text-start text-end)
                              nil)))))))))))

(defmethod sb-gray:stream-read-char ((s template-stream))
  ;; Pushback always wins. Re-incrementing CHARS-READ is correct
  ;; because UNREAD-CHAR decremented it.
  (when-let ((pb (ts-pushback s)))
    (setf (ts-pushback s) nil)
    (incf (ts-chars-read s))
    (return-from sb-gray:stream-read-char pb))
  (loop
    (when (null (ts-chunk s))
      (let ((next (ts-next-chunk s)))
        (when (eq next :eof)
          (return-from sb-gray:stream-read-char :eof))
        (setf (ts-chunk s)     (car next)
              (ts-chunk-pos s) 0)
        ;; The chunk's ANCHORS list enumerates transitions inside the
        ;; chunk between source-anchored and synthesized regions. Each
        ;; entry's CDR is either an integer source-byte or NIL. NIL
        ;; ANCHORS means the whole chunk is synthesized — push one
        ;; barrier at chunk start.
        (let ((anchors (cdr next))
            (base    (ts-chars-read s)))
          (cond
            ((null anchors)
             (ts-push-checkpoint s nil base))
            (t
             (dolist (cp anchors)
               (ts-push-checkpoint s (cdr cp) (+ base (car cp)))))))))
    (let ((str (ts-chunk s))
          (pos (ts-chunk-pos s)))
      (cond
        ((>= pos (length str))
         (setf (ts-chunk s) nil))
        (t
         (incf (ts-chunk-pos s))
         (incf (ts-chars-read s))
         (return-from sb-gray:stream-read-char (char str pos)))))))

(defmethod sb-gray:stream-unread-char ((s template-stream) char)
  (setf (ts-pushback s) char)
  (decf (ts-chars-read s))
  nil)

;;;; Embedded-language helpers.
;;;;
;;;; ELP files mix template text with embedded Lisp code. Tooling that
;;;; wants to operate on just the Lisp parts (Lisp-LSPs that don't know
;;;; ELP, formatters, linters) can use these to identify and extract
;;;; the code regions. Byte offsets are preserved end-to-end so editor
;;;; positions round-trip without translation.

(defun code-byte-ranges (text)
  "Return a list of (START . END) source-byte ranges that are code
   (`<% ... %>`) or expression (`<%= ... %>`) regions in TEXT.
   Comments are excluded.

   Bytes are interpreted as Latin-1 (1 byte = 1 character), matching
   ELP's existing model. UTF-8 multibyte content inside template text
   still tokenizes correctly (delimiters are ASCII), but non-ASCII
   inside a code region may not match an editor's UTF-8 / UTF-16
   position expectations.

   Built on the string-source backend — no foreign allocation, no
   Latin-1 sanitization. The ASCII-only `<%` / `%>` delimiters fall
   out of CL:SEARCH directly. UTF-8 multibyte content inside template
   text still tokenizes correctly (delimiters are ASCII), but
   character offsets inside a code region may not match an editor's
   UTF-8 / UTF-16 position expectations."
  (let* ((source (make-instance 'string-source :text text))
         (size   (source-length source))
         (stream (make-instance 'template-stream :source source))
         (ranges '()))
    (loop
      (when (>= (ts-cursor stream) size) (return))
      (let ((after-text-end (ts-find-code-start stream)))
        (when (eq after-text-end :eof) (return))
        ;; Cursor sits past `<%` or `<%-`. Classify the body flavor
        ;; by the byte at cursor — same logic as TS-PARSE-TAG-CHUNK,
        ;; but emitting source ranges instead of reader-ready chunks.
        (let* ((after-open (ts-cursor stream))
               (first-byte (and (< after-open size)
                                (source-byte source after-open)))
               (flavor (cond ((eql first-byte (char-code #\=)) :expr)
                             ((eql first-byte (char-code #\#)) :comment)
                             (t                                :code)))
               (body-start (if (eq flavor :code)
                               after-open
                               (1+ after-open))))
          (setf (ts-cursor stream) body-start)
          (let ((body-end (ts-find-code-end stream)))
            (unless (eq flavor :comment)
              (push (cons body-start body-end) ranges))))))
    (nreverse ranges)))

(defun extract-code-text (text)
  "Return TEXT with non-code regions blanked to whitespace, newlines
   preserved. Byte offsets and line/column positions in the result
   match TEXT exactly — useful for feeding through a Lisp-only parser
   while keeping editor coordinates round-trippable.

   Uses CHAR (not SCHAR) when reading from TEXT since LSP-provided
   strings can be non-simple."
  (let ((canvas (make-string (length text) :initial-element #\Space)))
    (loop for i from 0 below (length text)
          when (char= (char text i) #\Newline)
            do (setf (schar canvas i) #\Newline))
    (dolist (range (code-byte-ranges text))
      (loop for i from (car range) below (cdr range)
            do (setf (schar canvas i) (char text i))))
    canvas))

;;;; ============================================================
;;;; Public stream interface — full lambda form with position map.
;;;;
;;;; OPEN-TEMPLATE-STREAM-FROM-FILE / -FROM-STRING return a character
;;;; input stream whose drained contents are an analysis lambda form
;;;; for the template — same body shape the render path produces,
;;;; wrapped in stub bindings so a static walker / LSP sees every
;;;; symbol as a real lexical or function reference. Bytes produced
;;;; from the user's <% %> / <%= %> blocks are anchored;
;;;; STREAM-BYTE-POSITION translates reader positions into source bytes
;;;; (NIL for synthesized prefix/suffix/text-emit chars).
;;;;
;;;; The stream + position-map carry "translated text plus byte map"
;;;; through one object — a Lisp-LSP can DRAIN the stream into its
;;;; document-text slot and call STREAM-BYTE-POSITION for cursor
;;;; translation, without knowing anything about ELP's internals.
;;;;
;;;; Implementation:
;;;;   1. Build a SOURCE from the input (MMAP-SOURCE for a pathname,
;;;;      STRING-SOURCE for a Lisp string).
;;;;   2. Drain a TEMPLATE-STREAM over that source to capture
;;;;      (BODY-CHARS, POSITION-MAP).
;;;;   3. Walk the parsed body sexp for free variables.
;;;;   4. Synthesize an analysis lambda prefix (stub bindings for the
;;;;      body's WRITE-OUTPUT-RANGE refs, named &key per free var) and
;;;;      suffix; return a TEMPLATE-LAMBDA-STREAM that serves
;;;;      prefix → body → suffix.
;;;;
;;;; The analysis lambda doesn't COMPILE+RUN usefully — the stub
;;;; bindings are NIL, so calling it would error inside
;;;; WRITE-OUTPUT-RANGE. That's intentional: the consumer's job is
;;;; static analysis, not execution.

(defclass template-lambda-stream (sb-gray:fundamental-character-input-stream)
  ((prefix
    :initarg :prefix :reader ls-prefix
    :documentation "Synthesized lambda signature + stub-binding wrapper,
                    drained before the body chars. No source anchor.")
   (body
    :initarg :body :reader ls-body
    :documentation "Captured character stream from the inner
                    TEMPLATE-STREAM: text-emit forms, code blocks,
                    expr blocks. Anchored bytes come from the source.")
   (suffix
    :initarg :suffix :reader ls-suffix
    :documentation "Synthesized lambda closing forms. No source anchor.")
   (body-position-map
    :initarg :body-position-map :reader ls-body-position-map
    :documentation "POSITION-MAP from the inner TEMPLATE-STREAM at end
                    of drain. Keys are character positions into BODY.")
   (source-name
    :initarg :source-name :reader ls-source-name
    :documentation "Display name for the source (pathname for files,
                    caller-supplied for strings). Retained for
                    diagnostics.")
   (chars-read
    :initform 0 :accessor ls-chars-read)
   (pushback
    :initform nil :accessor ls-pushback))
  (:documentation
   "Character input stream serving the full analysis (lambda ...) form
    for an ELP template. Drains prefix, then body, then suffix in
    order. STREAM-BYTE-POSITION returns the originating source byte
    for body chars and NIL for prefix/suffix chars."))

(defmethod sb-gray:stream-read-char ((s template-lambda-stream))
  (when-let ((pb (ls-pushback s)))
    (setf (ls-pushback s) nil)
    (incf (ls-chars-read s))
    (return-from sb-gray:stream-read-char pb))
  (let* ((p      (ls-chars-read s))
         (prefix (ls-prefix s))
         (body   (ls-body s))
         (suffix (ls-suffix s))
         (pl     (length prefix))
         (bl     (length body))
         (sl     (length suffix)))
    (cond
      ((< p pl)
       (incf (ls-chars-read s))
       (char prefix p))
      ((< p (+ pl bl))
       (incf (ls-chars-read s))
       (char body (- p pl)))
      ((< p (+ pl bl sl))
       (incf (ls-chars-read s))
       (char suffix (- p pl bl)))
      (t :eof))))

(defmethod sb-gray:stream-unread-char ((s template-lambda-stream) char)
  (setf (ls-pushback s) char)
  (decf (ls-chars-read s))
  nil)

(defmethod stream-byte-position ((s template-lambda-stream)
                                 &optional (reader-pos (ls-chars-read s)))
  (let* ((pl       (length (ls-prefix s)))
         (bl       (length (ls-body s)))
         (body-pos (- reader-pos pl)))
    (cond
      ((< reader-pos pl) nil)
      ((>= reader-pos (+ pl bl)) nil)
      (t
       (when-let ((checkpoint (find-if (lambda (c) (<= (car c) body-pos))
                                       (ls-body-position-map s))))
         (destructuring-bind (cp-reader-pos . cp-source-byte) checkpoint
           (when cp-source-byte
             (+ cp-source-byte (- body-pos cp-reader-pos)))))))))

(defun %drain-template-stream (inner)
  "Read all characters from INNER (a TEMPLATE-STREAM) into a string.
   Returns (values CHARS POSITION-MAP) — the captured character output
   and INNER's final POSITION-MAP."
  (let ((out (make-string-output-stream)))
    (loop for c = (sb-gray:stream-read-char inner)
          until (eq c :eof)
          do (write-char c out))
    (values (get-output-stream-string out)
            (ts-position-map inner))))

(defun %body-free-vars (body-chars)
  "Walk the body sexp parsed from BODY-CHARS (the drained inner stream)
   for free variables, using a lexical-scope candidate that binds the
   names BUILD-TEMPLATE-LAMBDA's wrapper would (ELP::PTR / SIZE / FD /
   *current-template-span*), so wrapper-introduced names aren't
   surfaced as free."
  (let* ((body-sexp (with-input-from-string (in body-chars)
                      (let ((forms '()))
                        (loop for f = (read in nil :eof)
                              until (eq f :eof)
                              do (push f forms))
                        `(progn ,@(nreverse forms)))))
         (candidate
          `(lambda (&optional (stream *standard-output*))
             (let ((*standard-output* stream)
                   (elp::ptr nil) (elp::size nil) (elp::fd nil))
               (declare (ignorable elp::ptr elp::size elp::fd))
               ,body-sexp
               (values)))))
    (form-free-vars candidate)))

(defun %lambda-prefix (free-vars)
  "Synthesized text for the analysis lambda. Stub-binds ELP::PTR / SIZE
   / FD so the body's WRITE-OUTPUT-RANGE calls reference real lexicals
   (the LSP / walker sees them as bound, not free); declares all
   stubs and user kwargs ignorable; opens a (progn so the body forms
   line up as a sequence."
  (with-output-to-string (out)
    (format out "(lambda (stream &key")
    (dolist (var free-vars)
      (format out " ~A" (symbol-name var)))
    (format out " &allow-other-keys)~%")
    (format out "  (let ((elp::ptr nil) (elp::size nil) (elp::fd nil))~%")
    (format out "    (declare (ignorable stream elp::ptr elp::size elp::fd")
    (dolist (var free-vars)
      (format out " ~A" (symbol-name var)))
    (format out "))~%")
    (format out "    (progn~%      ")))

(defun %lambda-suffix ()
  (format nil ")))~%"))

(defun %open-template-lambda-stream (source)
  "Common back end of OPEN-TEMPLATE-STREAM-FROM-FILE and -FROM-STRING:
   given a SOURCE, drain it, walk for free vars, and return a
   TEMPLATE-LAMBDA-STREAM serving the full analysis lambda."
  (let* ((inner (make-instance 'template-stream :source source)))
    (multiple-value-bind (body-chars body-position-map)
        (%drain-template-stream inner)
      (let ((free-vars (%body-free-vars body-chars)))
        (make-instance 'template-lambda-stream
                       :prefix (%lambda-prefix free-vars)
                       :body body-chars
                       :suffix (%lambda-suffix)
                       :body-position-map body-position-map
                       :source-name (source-name source))))))

(defun open-template-stream-from-file (pathname)
  "Open PATHNAME as an .elp template and return a TEMPLATE-LAMBDA-STREAM
   serving its analysis lambda form. Backed by MMAP-SOURCE — the
   fast path for on-disk templates.

   Zero-byte files short-circuit through a STRING-SOURCE of \"\" so
   %mmap-open's size=0 EINVAL never surfaces.

   STREAM-BYTE-POSITION on the returned stream maps a reader position
   back to a source byte for bytes that originated in the .elp file,
   and to NIL for synthesized wrapper / delimiter / text-emit bytes."
  (let ((file-size (with-open-file (f pathname) (file-length f))))
    (when (zerop file-size)
      (return-from open-template-stream-from-file
        (%open-template-lambda-stream
         (make-instance 'string-source :text "" :name pathname)))))
  (let ((source (open-mmap-source pathname)))
    (unwind-protect (%open-template-lambda-stream source)
      (close-mmap-source source))))

(defun open-template-stream-from-string (text &key (name "<string>"))
  "Treat TEXT as an .elp template body and return a TEMPLATE-LAMBDA-STREAM
   serving its analysis lambda form. NAME (default \"<string>\") is the
   display name surfaced in error reports.

   The LSP-facing entry: passes the document text from a didChange
   directly — no on-disk file needed."
  (%open-template-lambda-stream
   (make-instance 'string-source :text text :name name)))

