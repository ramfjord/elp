;;;; ELP - A template system for Common Lisp
;;;; Inspired by ERB (Embedded Ruby), ELP allows embedding Lisp code in text files.
;;;; Syntax:
;;;;   <%= lisp-expression %>  - outputs the result
;;;;   <% lisp-code %>         - executes code without output
;;;;   <%# comment %>          - comments (removed from output)

(defpackage :elp
  (:use :cl)
  (:export
   ;; Primary public API
   :render
   :compile-template
   :template-code
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

(defvar *template-ptr* nil
  "When the file-path renderer is active, bound to the foreign pointer
   for the mmap'd template. The generated render sexp references this
   symbol when emitting WRITE-OUTPUT-RANGE calls, so the sexp itself
   stays free of free lexical variables and can be EVAL'd in the null
   lexical environment.")

;;;; Runtime helpers
;;;;
;;;; Functions tagged with DEFINE-HELPER are installed both as top-level
;;;; DEFUNs (for REPL / M-. ergonomics) and registered in
;;;; *HELPER-SOURCES*, so the codegen in BUILD-TEMPLATE-LAMBDA can
;;;; splice them into a LABELS block at the head of the generated
;;;; render program. That keeps TEMPLATE-CODE output self-contained:
;;;; a printed form can be re-EVAL'd without depending on these
;;;; specific internals being present.

(defvar *helper-sources* '()
  "List of (NAME LAMBDA-LIST . BODY) entries, in registration order, for
   helpers that should be embedded as LABELS in generated render code.")

(defmacro define-helper (name lambda-list &body body)
  "Like DEFUN, but also records the source under *HELPER-SOURCES* so the
   codegen can embed the helper as a LABELS clause."
  `(progn
     (setf *helper-sources*
           (append (remove ',name *helper-sources* :key #'car)
                   (list '(,name ,lambda-list ,@body))))
     (defun ,name ,lambda-list ,@body)))

(define-helper byte->line+column (ptr size byte-offset)
  "Return (values LINE COLUMN) — both 1-based — for BYTE-OFFSET in the
   mmap'd region PTR[0,SIZE). Counts newlines in the prefix
   [0, MIN(BYTE-OFFSET, SIZE)) using libc memchr, so the per-line cost
   is one foreign call rather than one read-char per byte. ASCII column
   semantics, same as the previous implementation."
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

(define-helper %mmap-open (pathname)
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

(define-helper %mmap-close (ptr size fd)
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

(define-helper %memchr (haystack-ptr haystack-len byte)
  "Return the byte offset of BYTE (an integer 0–255) in HAYSTACK-PTR[0,HAYSTACK-LEN),
   or NIL if not present. Wraps libc's vectorized memchr(3)."
  (let ((found (cffi:foreign-funcall "memchr"
                                     :pointer haystack-ptr :int byte
                                     :size    haystack-len
                                     :pointer)))
    (and (not (cffi:null-pointer-p found))
         (- (cffi:pointer-address found)
            (cffi:pointer-address haystack-ptr)))))

;;;; Public API

(defgeneric render (input context-alist &optional stream)
  (:documentation "Render a template from INPUT with CONTEXT-ALIST, writing
   directly to STREAM (defaults to *STANDARD-OUTPUT*).

   Output bytes go to STREAM as they are produced, with no intermediate
   Lisp string. When STREAM is an SB-SYS:FD-STREAM (e.g. the CLI's
   *STANDARD-OUTPUT* in a saved binary), text ranges are written via a
   single WRITE(2) syscall directly on the mmap'd source — zero copy
   through Lisp.

   INPUT is a pathname; the file is mmap'd once, walked by the standard
   Lisp reader through a TEMPLATE-STREAM (via BUILD-RENDER-FORM), and
   the resulting body sexp is evaluated against the same mapping.
   Returns no useful value; consumers care about side effects on
   STREAM. Wrap in WITH-OUTPUT-TO-STRING if you want the output as a
   string."))

(defun template-code (pathname)
  "Return the self-contained sexp that COMPILE-TEMPLATE compiles.
   Useful for debugging (`prin1` it) and for the CLI's `--print`
   flag. The form is a `(lambda (ctx &optional stream) …)` whose
   body uses PROGV to bind each context-alist key as a dynamic
   variable for the call's extent."
  (let ((file-size (with-open-file (f pathname) (file-length f))))
    (when (zerop file-size)
      (return-from template-code
        '(lambda (ctx &optional (stream *standard-output*))
          (declare (ignore ctx stream))
          (values)))))
  (multiple-value-bind (ptr size fd) (%mmap-open pathname)
    (let ((body (unwind-protect
                     (build-template-body pathname ptr size)
                  (%mmap-close ptr size fd))))
      (build-template-lambda pathname body))))

(defun build-template-lambda (pathname body)
  "Wrap BODY as a `(lambda (ctx &optional stream) …)` ready for
   COMPILE. Helpers from *HELPER-SOURCES* are spliced in as a LABELS
   block; the body runs under PROGV so context-alist keys bind as
   dynamic variables. Errors during render are translated to
   ELP-TEMPLATE-ERROR via the existing handler."
  (let ((helpers (mapcar (lambda (entry)
                           (destructuring-bind (name lambda-list &rest body) entry
                             `(,name ,lambda-list ,@body)))
                         *helper-sources*)))
    `(lambda (ctx &optional (stream *standard-output*))
       (let ((*standard-output* stream))
         (labels ,helpers
           (multiple-value-bind (ptr size fd) (%mmap-open ,pathname)
             (let ((*template-ptr* ptr))
               (unwind-protect
                    (handler-bind
                        ((elp-template-error (lambda (c) (error c)))
                         (error
                           (lambda (c)
                             (when *current-template-span*
                               (let ((byte (first *current-template-span*)))
                                 (multiple-value-bind (line col)
                                     (byte->line+column ptr size byte)
                                   (error 'elp-template-error
                                          :file ,pathname
                                          :line line :column col
                                          :original c)))))))
                      (progv (mapcar #'car ctx) (mapcar #'cdr ctx)
                        ,body))
                 (%mmap-close ptr size fd)))))
         (values)))))

(defun compile-template (pathname)
  "Compile the template at PATHNAME and return a function of
   (CTX &OPTIONAL STREAM). The function may be reused across calls
   with different context-alists; keys absent from CTX referenced
   by the template signal an unbound-variable error at the
   reference site, translated to ELP-TEMPLATE-ERROR with the
   correct line/column."
  (handler-bind ((warning #'muffle-warning))
    (compile nil (template-code pathname))))

(defmethod render ((fn function) context-alist
                   &optional (stream *standard-output*))
  (funcall fn context-alist stream))

(defmethod render ((pathname pathname) context-alist
                   &optional (stream *standard-output*))
  (render (compile-template pathname) context-alist stream))

;;;; Internal Helper Functions

(define-helper write-output-range (mmap-ptr start end &optional (stream *standard-output*))
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
   return the inner body sexp `(progn ,@forms)` — without any
   context-binding wrapper.

   Reader errors are translated into ELP-TEMPLATE-ERROR via the
   stream's POSITION-MAP — no intermediate body-string assembly,
   no checkpoints list reconstruction."
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
;;;;   NEXT-UNIT — straight-line state machine. Looks at the byte at
;;;;   CURSOR, parses the next syntactic unit (text-up-to-tag, plain
;;;;   <% %>, expr <%= %>, comment <%# %>, or trailing text), and
;;;;   appends its chunks to PENDING. A chunk is a cons
;;;;     (STRING . ANCHOR-BYTE-OR-NIL)
;;;;   where STRING is the characters to feed to the reader and
;;;;   ANCHOR is the source byte the chunk anchors at (NIL for
;;;;   synthesized wrappers that have no meaningful source position).
;;;;   Bodies of <% ... %> and <%= ... %> are materialized into
;;;;   STRING via one MMAP-SUBSTRING call — the reader sees them as
;;;;   ordinary characters, and per-char foreign dereference goes
;;;;   away.
;;;;
;;;;   STREAM-READ-CHAR — dumb. Drains CHUNK one character at a time;
;;;;   when exhausted, pulls the next chunk from PENDING (calling
;;;;   NEXT-UNIT to refill PENDING when empty). The only state
;;;;   transition that happens inside read-char is "this chunk is
;;;;   done, advance to the next" — never the tag-classification
;;;;   machinery.
;;;;
;;;; POSITION-MAP records (READER-POS . MMAP-BYTE) checkpoints, pushed
;;;; whenever a chunk with a non-nil ANCHOR becomes current — those
;;;; are the chunks whose characters correspond to real source bytes.

(defclass template-stream (sb-gray:fundamental-character-input-stream)
  ((ptr          :initarg :ptr        :reader   ts-ptr)
   (size         :initarg :size       :reader   ts-size)
   (cursor       :initform 0          :accessor ts-cursor
    :documentation "Next mmap byte NEXT-UNIT will look at.")
   (chunk        :initform nil        :accessor ts-chunk
    :documentation "Currently-draining chunk, or NIL when one is needed.")
   (chunk-pos    :initform 0          :accessor ts-chunk-pos
    :documentation "Index of next character to return from CHUNK.")
   (pending      :initform nil        :accessor ts-pending
    :documentation "Queue of (STRING . ANCHOR-OR-NIL) chunks parsed but
                    not yet drained. ANCHOR is non-nil when entering this
                    chunk should push a checkpoint at (chars-read . anchor).")
   (eof          :initform nil        :accessor ts-eof
    :documentation "T once NEXT-UNIT has reached SIZE.")
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
  (format nil "(elp::write-output-range elp::*template-ptr* ~D ~D) "
          start end))

(defun ts-whitespace-only-p (s start end)
  "T iff every byte in [START, END) is ASCII whitespace."
  (loop for i from start below end
        always (let ((b (%byte-at (ts-ptr s) i)))
                 (or (= b (char-code #\space))
                     (= b (char-code #\tab))
                     (= b (char-code #\newline))
                     (= b (char-code #\return))))))

(defun ts-find-close-delim (s from)
  "Return the byte offset of the next %> at or after FROM, or NIL."
  (let* ((size (ts-size s)))
    (when (<= from size)
      (let ((rel (%memmem (cffi:inc-pointer (ts-ptr s) from)
                          (- size from) "%>")))
        (and rel (+ from rel))))))

(defun ts-close-trim-p (s close)
  "T when the byte immediately before CLOSE (the offset of `%>`) is
   `-`, i.e. the close delimiter is `-%>`."
  (and close
       (>= close 1)
       (= (%byte-at (ts-ptr s) (1- close)) (char-code #\-))))

(defun ts-open-trim-p (s delim-pos)
  "T when the byte immediately after `<%` at DELIM-POS is `-`,
   i.e. the opening delimiter is `<%-`."
  (let ((after (+ delim-pos 2)))
    (and (< after (ts-size s))
         (= (%byte-at (ts-ptr s) after) (char-code #\-)))))

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

(defun ts-push-checkpoint (s anchor &optional (key (ts-chars-read s)))
  "Push (KEY . ANCHOR) onto S's POSITION-MAP unless it is already the
   most recent entry. Checkpoints are pushed every time the source of
   the next characters changes (text wrapper, code body, expr body)."
  (let ((top (car (ts-position-map s))))
    (unless (and top (= (car top) key) (= (cdr top) anchor))
      (push (cons key anchor) (ts-position-map s)))))

(defun stream-byte-position (s &optional (reader-pos (ts-chars-read s)))
  "Map READER-POS (defaulting to S's current CHARS-READ) to the
   corresponding mmap byte. Finds the largest checkpoint with
   key <= READER-POS and adds (READER-POS - key) to its anchor.
   Returns NIL when READER-POS precedes every checkpoint."
  (let ((best nil))
    (dolist (cp (ts-position-map s))
      (when (<= (car cp) reader-pos)
        (when (or (null best) (> (car cp) (car best)))
          (setf best cp))))
    (when best
      (+ (cdr best) (- reader-pos (car best))))))

(defun mmap-substring (ptr start end)
  "Materialize the mmap byte range [START, END) as a Lisp string,
   one char per byte (Latin-1 mapping). Used to feed the source bytes
   of a <% ... %> body to the standard reader without per-byte
   foreign dereferences."
  (cffi:foreign-string-to-lisp (cffi:inc-pointer ptr start)
                               :count (- end start)
                               :encoding :latin-1))

(defun ts-enqueue (s string anchor)
  "Append (STRING . ANCHOR) to the pending-chunk queue of S."
  (setf (ts-pending s) (nconc (ts-pending s) (list (cons string anchor)))))

(defun ts-parse-code-tag (s body-start)
  "Plain `<% code %>`. BODY-START points at the first body byte.
   Cursor advances past the closing `%>` (and one trailing newline
   if `-%>`)."
  (let* ((close (ts-find-close-delim s body-start))
         (trim  (ts-close-trim-p s close))
         (size  (ts-size s))
         (cend  (cond ((null close) size)
                      (trim         (1- close))
                      (t            close))))
    (setf (ts-cursor s) (if close (+ close 2) size))
    (when trim (ts-skip-trailing-newline s))
    ;; Body chunk. Always emitted (even if empty) so the checkpoint
    ;; anchors at BODY-START — preserves reader-pos → source-byte
    ;; lookups for the body region.
    (ts-enqueue s (mmap-substring (ts-ptr s) body-start cend) body-start)
    ;; Trailing space delimits this form from whatever the reader
    ;; reads next.
    (ts-enqueue s " " nil)))

(defun ts-parse-expr-tag (s eq-pos)
  "`<%= expr %>`. EQ-POS points at `=`; body starts at EQ-POS+1.
   Cursor advances past the closing `%>` (and one trailing newline
   if `-%>`). Whitespace-only bodies emit no chunks — matching the
   engine's existing treatment of `<%= %>`."
  (let* ((cstart (1+ eq-pos))
         (close  (ts-find-close-delim s cstart))
         (trim   (ts-close-trim-p s close))
         (size   (ts-size s))
         (cend   (cond ((null close) size)
                       (trim         (1- close))
                       (t            close))))
    (setf (ts-cursor s) (if close (+ close 2) size))
    (when trim (ts-skip-trailing-newline s))
    (unless (ts-whitespace-only-p s cstart cend)
      (ts-enqueue s
                  (format nil
                          "(let ((elp::*current-template-span* '(~D ~D))) (format t \"~~A\" "
                          cstart cend)
                  nil)
      (ts-enqueue s (mmap-substring (ts-ptr s) cstart cend) cstart)
      (ts-enqueue s ")) " nil))))

(defun ts-parse-comment-tag (s body-start)
  "`<%# comment %>`. Emits no chunks; just advances the cursor past
   the closing `%>` (and one trailing newline if `-%>`)."
  (let* ((close (ts-find-close-delim s body-start))
         (trim  (ts-close-trim-p s close)))
    (setf (ts-cursor s) (if close (+ close 2) (ts-size s)))
    (when trim (ts-skip-trailing-newline s))))

(defun ts-parse-tag (s delim-pos)
  "Cursor sits at `<%` (offset DELIM-POS). Classify the tag by the
   byte after the open delimiter — skipping one extra byte for `<%-`
   open-trim — and dispatch to the per-flavor parser."
  (let* ((size      (ts-size s))
         (after     (+ delim-pos (if (ts-open-trim-p s delim-pos) 3 2)))
         (next-byte (and (< after size) (%byte-at (ts-ptr s) after))))
    (cond
      ((and next-byte (= next-byte (char-code #\=)))
       (ts-parse-expr-tag s after))
      ((and next-byte (= next-byte (char-code #\#)))
       (ts-parse-comment-tag s (1+ after)))
      (t
       (ts-parse-code-tag s after)))))

(defun ts-next-unit (s)
  "Parse one syntactic unit at (TS-CURSOR S) and append its chunks
   to (TS-PENDING S). A unit is one of: leading text up to the next
   `<%`, a tag (`<% %>`, `<%= %>`, `<%# %>`), or trailing text to
   EOF. Some units emit zero chunks (a fully-trimmed text run, a
   comment, a whitespace-only `<%= %>`); the caller must loop on
   NEXT-UNIT until PENDING is non-empty or EOF is set."
  (let* ((ptr  (ts-ptr s))
         (size (ts-size s))
         (cur  (ts-cursor s)))
    (when (>= cur size)
      (setf (ts-eof s) t)
      (return-from ts-next-unit))
    (let* ((rel       (%memmem (cffi:inc-pointer ptr cur) (- size cur) "<%"))
           (delim-pos (and rel (+ cur rel))))
      (cond
        ((null delim-pos)
         ;; Trailing literal text to EOF.
         (when (> size cur)
           (ts-enqueue s (synth-text-form cur size) nil))
         (setf (ts-cursor s) size))
        ((> delim-pos cur)
         ;; Leading text run before a tag. The tag itself is parsed on
         ;; the next NEXT-UNIT call (cursor lands on `<%`).
         (let ((emit-end (if (ts-open-trim-p s delim-pos)
                             (max cur (ts-open-trim-emit-end s delim-pos))
                             delim-pos)))
           (when (> emit-end cur)
             (ts-enqueue s (synth-text-form cur emit-end) nil))
           (setf (ts-cursor s) delim-pos)))
        (t
         (ts-parse-tag s delim-pos))))))

(defmethod sb-gray:stream-read-char ((s template-stream))
  ;; Pushback always wins. Re-incrementing CHARS-READ is correct
  ;; because UNREAD-CHAR decremented it.
  (let ((pb (ts-pushback s)))
    (when pb
      (setf (ts-pushback s) nil)
      (incf (ts-chars-read s))
      (return-from sb-gray:stream-read-char pb)))
  (loop
    ;; Need a current chunk? Pop one from PENDING; refill via NEXT-UNIT
    ;; until PENDING has something or we hit EOF.
    (when (null (ts-chunk s))
      (loop while (and (null (ts-pending s)) (not (ts-eof s)))
            do (ts-next-unit s))
      (when (null (ts-pending s))
        (return-from sb-gray:stream-read-char :eof))
      (let ((next (pop (ts-pending s))))
        (setf (ts-chunk s)     (car next)
              (ts-chunk-pos s) 0)
        (when (cdr next)
          (ts-push-checkpoint s (cdr next)))))
    ;; Drain one char, or mark chunk exhausted and loop.
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

