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
                     (elp-template-error-original c)))))

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
;;;; *HELPER-SOURCES*, so the codegen in WRAP-RENDER-FORM can splice them
;;;; into a LABELS block at the head of the generated render program.
;;;; That keeps TEMPLATE-CODE output self-contained: a printed form can
;;;; be re-EVAL'd without depending on these specific internals being
;;;; present.

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

(defun template-code (pathname &optional context-alist)
  "Return a self-contained sexp that, when EVALuated, renders the template
   at PATHNAME to *STANDARD-OUTPUT*. The form embeds the runtime helpers
   as LABELS, opens its own mmap, runs the body under an error handler
   that translates host conditions into ELP-TEMPLATE-ERROR, and unmaps on
   the way out — eval-able anywhere ELP is loaded, without depending on
   any internal (non-exported) ELP symbol."
  (let ((file-size (with-open-file (f pathname) (file-length f))))
    (when (zerop file-size)
      (return-from template-code '(values))))
  (multiple-value-bind (ptr size fd) (%mmap-open pathname)
    (unwind-protect
         (wrap-render-form pathname
                           (build-render-form pathname ptr size context-alist))
      (%mmap-close ptr size fd))))

(defun wrap-render-form (pathname body)
  "Wrap BODY (the body sexp produced by BUILD-RENDER-FORM) with a LABELS
   block defining the runtime helpers and the MMAP-OPEN/CLOSE plumbing,
   producing a self-contained, EVAL-able form."
  (let ((helpers (mapcar (lambda (entry)
                           (destructuring-bind (name lambda-list &rest body) entry
                             `(,name ,lambda-list ,@body)))
                         *helper-sources*)))
    `(labels ,helpers
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
                  ,body)
             (%mmap-close ptr size fd))))
       (values))))

(defmethod render ((pathname pathname) context-alist
                   &optional (stream *standard-output*))
  (let ((*standard-output* stream))
    (eval (template-code pathname context-alist))))

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

(defun build-render-form (pathname ptr size &optional context-alist)
  "Read the template at PTR[0,SIZE) through a TEMPLATE-STREAM and
   return the executable body sexp. CONTEXT-ALIST is a list of
   (symbol . value) pairs wrapped in a LET around the body so that
   template expressions can reference the bound variables.

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
    (let* ((body     `(progn ,@(nreverse forms)))
           (bindings (mapcar (lambda (b) `(,(car b) ',(cdr b))) context-alist)))
      (if bindings `(let ,bindings ,body) body))))

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
;;;; Modes: :TEXT, :LISP, :EXPR-BODY. <%# comments are skipped during
;;;; the :TEXT-mode dispatch and produce no characters. The stream
;;;; tracks (CHARS-READ . MMAP-BYTE) checkpoints in POSITION-MAP, so
;;;; STREAM-BYTE-POSITION can translate a reader position back to a
;;;; source byte. RENDER-TO-STREAM consumes this stream via
;;;; BUILD-RENDER-FORM — there is no separate tokenizer phase.

(defclass template-stream (sb-gray:fundamental-character-input-stream)
  ((ptr          :initarg :ptr        :reader   ts-ptr)
   (size         :initarg :size       :reader   ts-size)
   (byte-cursor  :initform 0          :accessor ts-byte-cursor)
   (mode         :initform :text      :accessor ts-mode)
   (synth        :initform ""         :accessor ts-synth)
   (synth-pos    :initform 0          :accessor ts-synth-pos)
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
    to MMAP-BYTE in the source template (for chars that come from the
    mapping) or to the byte where the surrounding template construct
    began (for synthesized wrapper chars). STREAM-BYTE-POSITION uses
    it to translate a reader position back to a source byte."))

(defun %byte-at (ptr offset)
  (cffi:mem-aref (cffi:inc-pointer ptr offset) :unsigned-char 0))

(defun ts-emit-text-form (s start end)
  "Set the synth buffer to a (write-output-range ...) call covering
   the byte range [START, END)."
  (setf (ts-synth s)
        (format nil "(elp::write-output-range elp::*template-ptr* ~D ~D) "
                start end))
  (setf (ts-synth-pos s) 0))

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

(defun ts-skip-trailing-newline (s)
  "Advance S's byte cursor past at most one `\\r\\n` or `\\n`. Used
   after a close-trim `-%>` to drop the trailing line break."
  (let* ((cur  (ts-byte-cursor s))
         (size (ts-size s)))
    (cond
      ((and (<= (+ cur 2) size)
            (= (%byte-at (ts-ptr s) cur) (char-code #\return))
            (= (%byte-at (ts-ptr s) (1+ cur)) (char-code #\newline)))
       (setf (ts-byte-cursor s) (+ cur 2)))
      ((and (< cur size)
            (= (%byte-at (ts-ptr s) cur) (char-code #\newline)))
       (setf (ts-byte-cursor s) (1+ cur))))))

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

(defmethod sb-gray:stream-read-char ((s template-stream))
  (let ((pb (ts-pushback s)))
    (when pb
      (setf (ts-pushback s) nil)
      (incf (ts-chars-read s))
      (return-from sb-gray:stream-read-char pb)))
  (loop
    ;; Drain pending synthesized characters first.
    (let ((buf (ts-synth s))
          (sp  (ts-synth-pos s)))
      (when (< sp (length buf))
        (setf (ts-synth-pos s) (1+ sp))
        (incf (ts-chars-read s))
        (return-from sb-gray:stream-read-char (char buf sp))))
    ;; No synth chars: advance state machine.
    (ecase (ts-mode s)
      (:text
       (let* ((cur  (ts-byte-cursor s))
              (size (ts-size s)))
         (when (>= cur size)
           (return-from sb-gray:stream-read-char :eof))
         (let* ((rem       (- size cur))
                (rel       (%memmem (cffi:inc-pointer (ts-ptr s) cur)
                                    rem "<%"))
                (delim-pos (and rel (+ cur rel))))
           (cond
             ((and delim-pos (> delim-pos cur))
              ;; Emit a write-output-range form for [cur, delim-pos).
              ;; Cursor stops AT the delimiter; the next read will
              ;; re-enter :TEXT mode and dispatch by the byte after <%.
              ;; No checkpoint here: the wrapper chars are synth, not
              ;; mmap content, and the standard reader doesn't error
              ;; on its own valid output. POSITION-MAP entries are
              ;; only useful for queries that fall inside user code.
              (ts-emit-text-form s cur delim-pos)
              (setf (ts-byte-cursor s) delim-pos))
             ((null delim-pos)
              ;; Trailing literal text up to EOF.
              (cond ((> size cur)
                     (ts-emit-text-form s cur size)
                     (setf (ts-byte-cursor s) size))
                    (t (return-from sb-gray:stream-read-char :eof))))
             (t
              ;; Cursor sits at <%. Classify by the byte after the
              ;; opening delimiter and dispatch.
              (let* ((after (+ delim-pos 2))
                     (next-byte (and (< after size)
                                     (%byte-at (ts-ptr s) after))))
                (cond
                  ;; <%= expression block
                  ((and next-byte (= next-byte (char-code #\=)))
                   (let* ((cstart (1+ after))
                          (close  (ts-find-close-delim s cstart))
                          (trim   (ts-close-trim-p s close))
                          (cend   (cond ((null close) size)
                                        (trim (1- close))
                                        (t close))))
                     (cond
                       ((ts-whitespace-only-p s cstart cend)
                        ;; Empty/whitespace-only expr: skip without
                        ;; emitting anything, matching the existing
                        ;; engine's treatment of <%= %>.
                        (setf (ts-byte-cursor s)
                              (if close (+ close 2) size))
                        (when trim (ts-skip-trailing-newline s)))
                       (t
                        ;; Checkpoint anchored at the first body byte
                        ;; (CSTART), keyed at the chars-read value
                        ;; the reader will reach AFTER draining the
                        ;; let-prefix synth. The prefix itself is
                        ;; valid Lisp the reader will not error on.
                        (let ((prefix
                                (format nil
                                        "(let ((elp::*current-template-span* '(~D ~D))) (format t \"~~A\" "
                                        cstart cend)))
                          (ts-push-checkpoint s cstart
                                              (+ (ts-chars-read s)
                                                 (length prefix)))
                          (setf (ts-synth s) prefix)
                          (setf (ts-synth-pos s) 0)
                          (setf (ts-byte-cursor s) cstart)
                          (setf (ts-mode s) :expr-body))))))
                  ;; <%# comment block — skip entirely.
                  ((and next-byte (= next-byte (char-code #\#)))
                   (let* ((cstart (1+ after))
                          (close  (ts-find-close-delim s cstart))
                          (trim   (ts-close-trim-p s close)))
                     (setf (ts-byte-cursor s)
                           (if close (+ close 2) size))
                     (when trim (ts-skip-trailing-newline s))))
                  ;; Plain <% code block.
                  (t
                   (ts-push-checkpoint s after)
                   (setf (ts-byte-cursor s) after)
                   (setf (ts-mode s) :lisp)))))))))
      ((:lisp :expr-body)
       (let* ((cur  (ts-byte-cursor s))
              (size (ts-size s)))
         (cond
           ((>= cur size)
            ;; Unterminated <% block. Returning :EOF from inside a
            ;; reader-driven read causes the standard reader to signal
            ;; END-OF-FILE, which BUILD-RENDER-FORM catches and routes
            ;; through TRANSLATE-READ-ERROR.
            (return-from sb-gray:stream-read-char :eof))
           ((and (<= (+ cur 3) size)
                 (= (%byte-at (ts-ptr s) cur)       (char-code #\-))
                 (= (%byte-at (ts-ptr s) (1+ cur))  (char-code #\%))
                 (= (%byte-at (ts-ptr s) (+ cur 2)) (char-code #\>)))
            ;; Close-trim `-%>`: drop the `-`, consume `%>`, and skip
            ;; one trailing newline before re-entering :TEXT.
            (let ((suffix (if (eq (ts-mode s) :expr-body) ")) " " ")))
              (setf (ts-byte-cursor s) (+ cur 3))
              (setf (ts-mode s) :text)
              (setf (ts-synth s) suffix)
              (setf (ts-synth-pos s) 0)
              (ts-skip-trailing-newline s)))
           ((and (<= (+ cur 2) size)
                 (= (%byte-at (ts-ptr s) cur)       (char-code #\%))
                 (= (%byte-at (ts-ptr s) (1+ cur))  (char-code #\>)))
            (let ((suffix (if (eq (ts-mode s) :expr-body) ")) " " ")))
              (setf (ts-byte-cursor s) (+ cur 2))
              (setf (ts-mode s) :text)
              (setf (ts-synth s) suffix)
              (setf (ts-synth-pos s) 0)))
           (t
            (let ((b (%byte-at (ts-ptr s) cur)))
              (setf (ts-byte-cursor s) (1+ cur))
              (incf (ts-chars-read s))
              (return-from sb-gray:stream-read-char (code-char b))))))))))

(defmethod sb-gray:stream-unread-char ((s template-stream) char)
  (setf (ts-pushback s) char)
  (decf (ts-chars-read s))
  nil)

