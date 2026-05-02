;;;; ELP - A template system for Common Lisp
;;;; Inspired by ERB (Embedded Ruby), ELP allows embedding Lisp code in text files.
;;;; Syntax:
;;;;   <%= lisp-expression %>  - outputs the result
;;;;   <% lisp-code %>         - executes code without output
;;;;   <%# comment %>          - comments (removed from output)

(defpackage :elp
  (:use :cl :alexandria)
  (:export
   ;; Primary public API
   :render
   :compile-template
   ;; Error condition
   :elp-template-error
   :elp-template-error-file
   :elp-template-error-line
   :elp-template-error-column
   :elp-template-error-original))


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

;;;; Runtime helpers
;;;;
;;;; Plain package-internal DEFUNs. The generated render lambda
;;;; references them by package-qualified name (`elp::%mmap-open`,
;;;; `elp::byte->line+column`, etc.), so the lambda depends on the
;;;; :elp package being loaded — same as it depends on `elp::
;;;; *current-template-span*` and the ELP-TEMPLATE-ERROR condition
;;;; class. We don't try to make the printed lambda re-evaluable in
;;;; isolation; that would also require splicing the condition
;;;; class definition and the special variable, which we don't.

(defun byte->line+column (ptr size byte-offset)
  "Return (values LINE COLUMN) — both 1-based — for BYTE-OFFSET in the
   mmap'd region PTR[0,SIZE). ASCII column semantics. Counts newlines
   in the prefix [0, MIN(BYTE-OFFSET, SIZE)) using libc memchr, so the
   per-line cost is one foreign call rather than one read-char per byte."
  (let* ((target (min byte-offset size))
         (line 1)
         (line-start 0)
         (cursor 0))
    (loop while (< cursor target) do
      (let ((rel (%memchr (cffi:inc-pointer ptr cursor)
                          (- target cursor)
                          (char-code #\newline))))
        (cond
          ((null rel) (return))
          (t (incf line)
             (setf line-start (+ cursor rel 1))
             (setf cursor line-start)))))
    (values line (1+ (- target line-start)))))

;;;; mmap support

(defconstant +prot-read+   #x1)
(defconstant +map-private+ #x2)
(defconstant +o-rdonly+    0)

(defun %mmap-open (pathname)
  "Open PATHNAME read-only and mmap it. Returns (values mmap-pointer file-size fd)."
  (let* ((namestr (namestring pathname))
         (fd (cffi:foreign-funcall "open" :string namestr :int #.+o-rdonly+ :int))
         (size (with-open-file (f pathname) (file-length f))))
    (when (< fd 0)
      (error "open(2) failed for ~A" pathname))
    (let ((ptr (cffi:foreign-funcall "mmap"
                                     :pointer (cffi:null-pointer)
                                     :size    size
                                     :int     #.+prot-read+
                                     :int     #.+map-private+
                                     :int     fd
                                     :size    0
                                     :pointer)))
      (when (cffi:pointer-eq ptr (cffi:make-pointer (1- (expt 2 64))))
        (cffi:foreign-funcall "close" :int fd :int)
        (error "mmap(2) failed for ~A" pathname))
      (values ptr size fd))))

(defun %mmap-close (ptr size fd)
  "Unmap PTR (of SIZE bytes) and close FD."
  (cffi:foreign-funcall "munmap" :pointer ptr :size size :int)
  (cffi:foreign-funcall "close"  :int fd :int))

;;;; Vectorized byte search (libc memmem / memchr)

(defun %memmem (haystack-ptr haystack-len needle)
  "Return the byte offset of NEEDLE (an ASCII string) in HAYSTACK-PTR[0,HAYSTACK-LEN),
   or NIL if not present. Wraps glibc's vectorized memmem(3)."
  (cffi:with-foreign-string ((nptr nbytes) needle
                             :encoding :ascii
                             :null-terminated-p nil)
    (let ((found (cffi:foreign-funcall "memmem"
                                       :pointer haystack-ptr :size haystack-len
                                       :pointer nptr         :size nbytes
                                       :pointer)))
      (and (not (cffi:null-pointer-p found))
           (- (cffi:pointer-address found)
              (cffi:pointer-address haystack-ptr))))))

(defun %memchr (haystack-ptr haystack-len byte)
  "Return the byte offset of BYTE (an integer 0–255) in HAYSTACK-PTR[0,HAYSTACK-LEN),
   or NIL if not present. Wraps libc's vectorized memchr(3)."
  (let ((found (cffi:foreign-funcall "memchr"
                                     :pointer haystack-ptr :int byte
                                     :size    haystack-len
                                     :pointer)))
    (and (not (cffi:null-pointer-p found))
         (- (cffi:pointer-address found)
            (cffi:pointer-address haystack-ptr)))))

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
  (multiple-value-bind (ptr size fd) (%mmap-open pathname)
    (let ((body (unwind-protect
                     (build-template-body pathname ptr size)
                  (%mmap-close ptr size fd))))
      (build-template-lambda pathname body))))

(defun build-template-lambda (pathname body)
  "Wrap BODY as a `(lambda (stream &key …))` ready for COMPILE. Each
   free variable in BODY becomes a keyword parameter that errors with
   UNBOUND-VARIABLE when its key is absent at call time.

   Free vars are determined by walking a candidate form that mirrors
   the wrapper's lexical scope (multiple-value-bind etc.), so wrapper-
   introduced names like PTR / SIZE / FD aren't surfaced as free. The
   walk runs against a lambda with no &key params, so the keyword
   list is always free of itself."
  (let* ((handler-clauses
          `((elp-template-error (lambda (c) (error c)))
            (error
              (lambda (c)
                (multiple-value-bind (line col)
                    (if *current-template-span*
                        (byte->line+column ptr size
                                           (first *current-template-span*))
                        (values 1 1))
                  (error 'elp-template-error
                         :file ,pathname
                         :line line :column col
                         :original c))))))
         ;; Candidate has the wrapper's lexical scope with BODY inline
         ;; and no &key params. Walking it tells us which symbols are
         ;; free with respect to the wrapper's own bindings.
         (candidate
          `(lambda (&optional (stream *standard-output*))
             (let ((*standard-output* stream))
               (multiple-value-bind (ptr size fd) (%mmap-open ,pathname)
                 (unwind-protect (handler-bind ,handler-clauses ,body)
                   (%mmap-close ptr size fd)))
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
         ;; If we used `(error 'unbound-variable …)` as a &key default
         ;; the signal would fire outside handler-bind and escape.
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
         (multiple-value-bind (ptr size fd) (%mmap-open ,pathname)
           (unwind-protect
                (handler-bind ,handler-clauses
                  ,@key-checks
                  ,body-fresh)
             (%mmap-close ptr size fd))))
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

(defun build-template-body (pathname ptr size)
  "Read the template at PTR[0,SIZE) through a TEMPLATE-STREAM and
   return the inner body sexp `(progn ,@forms)`. Reader errors are
   translated into ELP-TEMPLATE-ERROR via the stream's POSITION-MAP."
  (let* ((stream (make-instance 'template-stream :ptr ptr :size size))
         (forms  '()))
    (handler-case
        (loop for form = (read stream nil :eof)
              until (eq form :eof)
              do (push form forms))
      ((or reader-error end-of-file) (c)
        (translate-read-error c pathname ptr size stream)))
    `(progn ,@(nreverse forms))))

(defun translate-read-error (condition pathname ptr size stream)
  "Translate a reader-error raised while reading STREAM into an
   ELP-TEMPLATE-ERROR pointing at the source byte that produced the
   offending reader position. Falls back to byte 0 when the stream
   has not yet reached any checkpoint."
  (let* ((reader-pos (ts-chars-read stream))
         (file-byte  (or (stream-byte-position stream reader-pos) 0)))
    (multiple-value-bind (line col) (byte->line+column ptr size file-byte)
      (error 'elp-template-error
             :file pathname :line line :column col
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
  ((ptr          :initarg :ptr        :reader   ts-ptr)
   (size         :initarg :size       :reader   ts-size)
   (cursor       :initform 0          :accessor ts-cursor
    :documentation "Next mmap byte NEXT-CHUNK will look at.")
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
   "Gray input stream wrapping an mmap'd ELP template. The standard
    Lisp reader can READ from it directly; the stream synthesizes
    WRITE-OUTPUT-RANGE wrapper forms around literal text spans and
    feeds the bytes inside <% ... %> blocks straight through.

    POSITION-MAP records (READER-POS . MMAP-BYTE) checkpoints, oldest
    last (push to front). A checkpoint says: at the moment the reader
    has consumed READER-POS chars, the next character will correspond
    to MMAP-BYTE in the source template. STREAM-BYTE-POSITION uses it
    to translate a reader position back to a source byte."))

(defun %byte-at (ptr offset)
  (cffi:mem-aref (cffi:inc-pointer ptr offset) :unsigned-char 0))

(defun synth-text-form (start end)
  "Source string for a (write-output-range ...) call covering the byte
   range [START, END). Trailing space terminates the form so the next
   chunk's content does not run into the closing paren."
  (format nil "(elp::write-output-range elp::ptr ~D ~D) "
          start end))

(defparameter *blank-rx* (cl-ppcre:create-scanner "^\\s*$")
  "Pre-compiled scanner for blank-or-whitespace-only strings; matches
   <%= %> bodies that should be silently skipped.")

(defun ts-advance-cursor (s needle)
  "Search for NEEDLE in the mmap starting at (TS-CURSOR S). On hit,
   advance CURSOR to the byte immediately past NEEDLE and return the
   match's start byte. On miss, advance CURSOR to SIZE and return
   NIL. After the call CURSOR sits at the boundary the caller would
   want to resume from."
  (let* ((cur  (ts-cursor s))
         (size (ts-size s))
         (rel  (%memmem (cffi:inc-pointer (ts-ptr s) cur)
                        (- size cur) needle)))
    (cond
      (rel
       (let ((match-start (+ cur rel)))
         (setf (ts-cursor s) (+ match-start (length needle)))
         match-start))
      (t
       (setf (ts-cursor s) size)
       nil))))

(defun ts-close-trim-p (s close)
  "T when the byte immediately before CLOSE (the offset of `%>`) is
   `-`, i.e. the close delimiter is `-%>`."
  (and close
       (>= close 1)
       (= (%byte-at (ts-ptr s) (1- close)) (char-code #\-))))

(defun ts-open-trim-emit-end (s delim-pos)
  "Walk backward from DELIM-POS over ASCII space/tab bytes. If the walk
   reaches a newline, return the position just past it; if it reaches
   the start of the file through pure whitespace, return 0. Otherwise
   return DELIM-POS (no trim — there is non-whitespace on the line)."
  (let ((i (1- delim-pos)))
    (loop while (>= i 0) do
      (let ((b (%byte-at (ts-ptr s) i)))
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
  (let* ((cur  (ts-cursor s))
         (size (ts-size s)))
    (cond
      ((and (<= (+ cur 2) size)
            (= (%byte-at (ts-ptr s) cur) (char-code #\return))
            (= (%byte-at (ts-ptr s) (1+ cur)) (char-code #\newline)))
       (setf (ts-cursor s) (+ cur 2)))
      ((and (< cur size)
            (= (%byte-at (ts-ptr s) cur) (char-code #\newline)))
       (setf (ts-cursor s) (1+ cur))))))

(defun ts-find-code-start (s)
  "Advance cursor to just past the next opening delimiter (`<%` or
   `<%-`) and return the byte position where the preceding literal
   text run ends. Open-trim (`<%-`) pulls the end back over leading
   whitespace and the preceding newline, so a blank prefix line is
   dropped from the literal run. Returns :EOF when no further `<%`
   exists; in that case cursor sits at SIZE."
  (let ((delim-start (ts-advance-cursor s "<%")))
    (cond
      ((null delim-start) :eof)
      (t
       (let ((open-trim (and (< (ts-cursor s) (ts-size s))
                             (= (%byte-at (ts-ptr s) (ts-cursor s))
                                (char-code #\-)))))
         (when open-trim (incf (ts-cursor s)))
         (if open-trim
             (ts-open-trim-emit-end s delim-start)
             delim-start))))))

(defun ts-find-code-end (s)
  "Advance cursor past the closing delimiter (`%>`, plus one trailing
   newline if `-%>`) and return the byte position where the tag body
   ends. If no closing `%>` exists, cursor goes to SIZE and SIZE is
   returned."
  (let ((close (ts-advance-cursor s "%>")))
    (cond
      ((null close) (ts-size s))
      ((ts-close-trim-p s close)
       (ts-skip-trailing-newline s)
       (1- close))
      (t close))))

(defun ts-push-checkpoint (s anchor &optional (key (ts-chars-read s)))
  "Push (KEY . ANCHOR) onto S's POSITION-MAP unless it is already the
   most recent entry. Checkpoints are pushed every time the source of
   the next characters changes (text wrapper, code body, expr body)."
  (let ((top (car (ts-position-map s))))
    (unless (and top
                 (destructuring-bind (top-key . top-anchor) top
                   (and (= top-key key) (= top-anchor anchor))))
      (push (cons key anchor) (ts-position-map s)))))

(defun stream-byte-position (s &optional (reader-pos (ts-chars-read s)))
  "Map READER-POS (defaulting to S's current CHARS-READ) to the
   corresponding mmap byte. POSITION-MAP is pushed newest-first with
   monotonically increasing keys, so it is sorted descending — the
   first entry with key <= READER-POS is the largest such entry.
   Returns NIL when READER-POS precedes every checkpoint."
  (when-let ((checkpoint (find-if (lambda (c) (<= (car c) reader-pos))
                                  (ts-position-map s))))
    (destructuring-bind (cp-reader-pos . cp-mmap-byte) checkpoint
      (+ cp-mmap-byte (- reader-pos cp-reader-pos)))))

(defun mmap-substring (ptr start end)
  "Materialize the mmap byte range [START, END) as a Lisp string,
   one char per byte (Latin-1 mapping). Used to feed the source bytes
   of a <% ... %> body to the standard reader without per-byte
   foreign dereferences."
  (cffi:foreign-string-to-lisp (cffi:inc-pointer ptr start)
                               :count (- end start)
                               :encoding :latin-1))

(defun ts-parse-tag-chunk (s)
  "Cursor sits just past the open delimiter (`<%` or `<%-`). Classify
   by the byte at cursor (`=` expr / `#` comment / anything else
   plain code), advance cursor past the closing `%>` (and one
   trailing newline if `-%>`), clear INSIDE-CODE, and return the
   chunk — or NIL for tags that emit nothing.

   The chunk is (STRING . ANCHOR), where ANCHOR is (CHAR-OFFSET .
   SOURCE-BYTE) for tags whose STRING contains source bytes (code,
   expr) and NIL otherwise. CHAR-OFFSET is where the source bytes
   start within STRING (0 for code, prefix-length for expr)."
  (let* ((size       (ts-size s))
         (after-open (ts-cursor s))
         (first      (and (< after-open size)
                          (%byte-at (ts-ptr s) after-open)))
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
         ;; Body bytes followed by a delimiting space. Anchor at
         ;; offset 0 — STRING's first char is BODY-START in source.
         (let ((body (mmap-substring (ts-ptr s) body-start body-end)))
           (cons (concatenate 'string body " ")
                 (cons 0 body-start))))
        (:expr
         ;; Whitespace-only <%= %> silently emits nothing — surfacing
         ;; it would only produce a render-time FORMAT error with no
         ;; obvious link back to the empty body.
         (let ((body (mmap-substring (ts-ptr s) body-start body-end)))
           (unless (cl-ppcre:scan *blank-rx* body)
             (let ((prefix (format nil
                                   "(let ((elp::*current-template-span* '(~D ~D))) (format t \"~~A\" "
                                   body-start body-end)))
               (cons (concatenate 'string prefix body ")) ")
                     (cons (length prefix) body-start))))))))))

(defun ts-next-chunk (s)
  "Parse the next syntactic unit at (TS-CURSOR S) and return its
   chunk, or :EOF when CURSOR has reached SIZE. Dispatches on
   INSIDE-CODE: T means cursor sits past `<%` and the next unit is a
   tag; NIL means scan forward for the next tag, emitting any
   leading text run as a chunk. Loops internally to skip units that
   emit no chunk (comments, whitespace-only <%= %>, fully-trimmed
   text runs)."
  (loop
    (when (>= (ts-cursor s) (ts-size s))
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
            (return (cons (synth-text-form text-start (ts-size s)) nil)))
           (t
            (setf (ts-inside-code s) t)
            (when (> text-end text-start)
              (return (cons (synth-text-form text-start text-end)
                            nil))))))))))

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
        (when-let ((anchor (cdr next)))
          (ts-push-checkpoint s (cdr anchor)
                              (+ (ts-chars-read s) (car anchor))))))
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

