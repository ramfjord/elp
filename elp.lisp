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
   :render-to-stream
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

(defun byte->line+column (ptr size byte-offset)
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

(defun %mmap-open (pathname)
  "Open PATHNAME read-only and mmap it. Returns (values mmap-pointer file-size fd)."
  (let* ((namestr (namestring pathname))
         (fd (cffi:foreign-funcall "open" :string namestr :int +o-rdonly+ :int))
         (size (with-open-file (f pathname) (file-length f))))
    (when (< fd 0)
      (error "open(2) failed for ~A" pathname))
    (let ((ptr (cffi:foreign-funcall "mmap"
                                     :pointer (cffi:null-pointer)
                                     :size    size
                                     :int     +prot-read+
                                     :int     +map-private+
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

;;;; Public API

(defgeneric render-to-stream (input context-alist &optional stream)
  (:documentation "Render a template from INPUT with CONTEXT-ALIST, writing
   directly to STREAM (defaults to *STANDARD-OUTPUT*).

   This is the streaming primitive: output bytes go to STREAM as they are
   produced, with no intermediate Lisp string. When STREAM is an
   SB-SYS:FD-STREAM (e.g. the CLI's *STANDARD-OUTPUT* in a saved binary),
   text ranges are written via a single WRITE(2) syscall directly on the
   mmap'd source — zero copy through Lisp.

   INPUT is a pathname; the file is mmap'd once, tokenized via
   TOKENIZE-MMAP, and the generated body is evaluated against that same
   mapping. Returns no useful value; consumers care about side effects on
   STREAM. Use RENDER if you want the output as a string."))

(defgeneric render (input context)
  (:documentation "Render a template from INPUT with CONTEXT variable bindings,
   returning the rendered output as a string.

   Thin wrapper around RENDER-TO-STREAM for callers that genuinely want a
   string (tests, library consumers building HTTP bodies, etc.). Streaming
   callers (the CLI, file exporters) should use RENDER-TO-STREAM directly
   to avoid materializing the entire output in Lisp memory."))

(defmethod render-to-stream ((pathname pathname) context-alist
                             &optional (stream *standard-output*))
  (let ((file-size (with-open-file (f pathname) (file-length f))))
    ;; Linux mmap rejects size 0 with EINVAL. Skip the mapping entirely.
    (when (zerop file-size)
      (return-from render-to-stream (values))))
  (multiple-value-bind (ptr size fd) (%mmap-open pathname)
    (unwind-protect
         (let ((tokens (tokenize-mmap ptr size)))
           (multiple-value-bind (sexp checkpoints body-string)
               (generate-render-code pathname ptr size tokens context-alist)
             (declare (ignore checkpoints body-string))
             (let ((*template-ptr* ptr)
                   (*standard-output* stream))
               (handler-bind
                   ((elp-template-error (lambda (c) (error c)))
                    (error
                      (lambda (c)
                        (when *current-template-span*
                          (let ((byte (first *current-template-span*)))
                            (multiple-value-bind (line col)
                                (byte->line+column ptr size byte)
                              (error 'elp-template-error
                                     :file pathname :line line :column col
                                     :original c)))))))
                 (eval sexp)))))
      (%mmap-close ptr size fd)))
  (values))

(defmethod render ((pathname pathname) context-alist)
  (with-output-to-string (s)
    (render-to-stream pathname context-alist s)))

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

(defun generate-render-code (pathname ptr size tokens &optional context-alist)
  "Generate an executable sexp from PATHNAME and its TOKENS.

   Builds the template body as a single string — code token content is spliced
   in raw, text and expr tokens emit write-output-range/format calls — then
   calls read-from-string once on the whole thing.  This means multi-token
   constructs like loops work naturally: open parens in one code block are
   closed by a later one.

   The returned sexp is a plain (progn …) referencing ELP::*TEMPLATE-PTR*
   for the mmap base pointer; the caller (RENDER-TO-STREAM) is
   responsible for opening the mmap and binding *TEMPLATE-PTR* around
   EVAL.

   CONTEXT-ALIST is a list of (symbol . value) pairs bound as variables
   available to template expressions."
  (let ((out (make-string-output-stream))
        (checkpoints '()))
    (write-string "(progn " out)
    (dolist (token tokens)
      (let ((type         (first token))
            (content      (second token))
            (start        (third token))
            (end          (fourth token))
            (content-start (fifth token))
            (content-end   (sixth token)))
        (declare (ignore end))
        (case type
          (:text
           (format out "(elp::write-output-range elp::*template-ptr* ~D ~D) "
                   start content-end))
          (:expr
           (unless (zerop (length (string-trim '(#\space #\tab #\newline) content)))
             (format out "(let ((elp::*current-template-span* '(~D ~D))) (format t \"~~A\" "
                     content-start content-end)
             (push (cons (file-position-of-stream out) content-start) checkpoints)
             (write-string content out)
             (write-string ")) " out)))
          (:code
           (push (cons (file-position-of-stream out) content-start) checkpoints)
           (write-string content out)
           (write-char #\space out))
          (:comment nil))))
    (write-string ")" out)
    (let* ((body-string (get-output-stream-string out))
           (checkpoints (nreverse checkpoints))
           (body (handler-case
                     (read-from-string body-string)
                   ((or reader-error end-of-file) (c)
                     (translate-read-error c pathname ptr size
                                           body-string checkpoints))))
           (bindings    (mapcar (lambda (b) `(,(car b) ',(cdr b))) context-alist))
           (body-with-context (if bindings `(let ,bindings ,body) body)))
      (values body-with-context checkpoints body-string))))

(defun file-position-of-stream (stream)
  "Length (in characters) written so far to a string-output-stream."
  (file-position stream))

(defun body-offset->file-byte (offset checkpoints)
  "Given a char offset into the body-string, find the nearest preceding
   checkpoint and compute the corresponding file byte offset.  Returns NIL
   when OFFSET is before any checkpoint."
  (let ((best nil))
    (dolist (cp checkpoints)
      (when (<= (car cp) offset)
        (setf best cp)))
    (when best
      (+ (cdr best) (- offset (car best))))))

(defun translate-read-error (condition pathname ptr size body-string checkpoints)
  "Translate a reader-error raised while reading BODY-STRING into an
   elp-template-error that points into PATHNAME using CHECKPOINTS.
   PTR/SIZE name the live mmap of PATHNAME used for line/column lookup."
  (let* ((offset (or (ignore-errors
                      (with-input-from-string (s body-string)
                        (handler-case
                            (progn (read s) (file-position s))
                          (error () (file-position s)))))
                     (length body-string)))
         (file-byte (or (body-offset->file-byte offset checkpoints)
                        (cdar (last checkpoints))
                        0)))
    (multiple-value-bind (line col) (byte->line+column ptr size file-byte)
      (error 'elp-template-error
             :file pathname :line line :column col
             :original condition))))

(defun tokenize-mmap (ptr size)
  "Tokenize the byte range PTR[0,SIZE) as an ELP template.

   Returns the same shape as TOKENIZE-FILE: a list of
   (type content start end content-start content-end). For :text and
   :comment tokens, CONTENT is NIL — the bytes live in the mmap and
   the renderer reads them directly via offsets. For :code and :expr,
   CONTENT is a trimmed Lisp string extracted from the mapped region
   via foreign-string-to-lisp; its size is bounded by embedded-code
   length, not template length."
  (let ((tokens '())
        (pos 0))
    (loop while (< pos size) do
      (let* ((rem (- size pos))
             (base (cffi:inc-pointer ptr pos))
             (rel-comment (%memmem base rem "<%#"))
             (rel-expr    (%memmem base rem "<%="))
             (rel-code    (%memmem base rem "<%"))
             (comment-pos (and rel-comment (+ pos rel-comment)))
             (expr-pos    (and rel-expr    (+ pos rel-expr)))
             (code-pos    (and rel-code    (+ pos rel-code)))
             (next-delim nil) (delim-type nil) (delim-len nil))
        (when comment-pos
          (setf next-delim comment-pos delim-type :comment delim-len 3))
        (when (and expr-pos (or (not comment-pos) (< expr-pos comment-pos)))
          (setf next-delim expr-pos delim-type :expr delim-len 3))
        (when (and code-pos (or (not comment-pos) (< code-pos comment-pos))
                            (or (not expr-pos)    (< code-pos expr-pos)))
          (setf next-delim code-pos delim-type :code delim-len 2))
        (cond
          ((not next-delim)
           (push (list :text nil pos size pos size) tokens)
           (setf pos size))
          (t
           (when (< pos next-delim)
             (push (list :text nil pos next-delim pos next-delim) tokens))
           (let* ((content-start (+ next-delim delim-len))
                  (rel-close (and (<= content-start size)
                                  (%memmem (cffi:inc-pointer ptr content-start)
                                           (- size content-start)
                                           "%>")))
                  (close-pos (and rel-close (+ content-start rel-close))))
             (cond
               (close-pos
                (let* ((token-end (+ close-pos 2))
                       (extract (cffi:foreign-string-to-lisp
                                 (cffi:inc-pointer ptr content-start)
                                 :count (- close-pos content-start)
                                 :encoding :utf-8))
                       (trimmed (string-trim '(#\space #\tab #\newline) extract)))
                  (push (list delim-type
                              (if (eq delim-type :comment) nil trimmed)
                              next-delim token-end content-start close-pos)
                        tokens)
                  (setf pos token-end)))
               (t
                (let* ((extract (cffi:foreign-string-to-lisp
                                 (cffi:inc-pointer ptr content-start)
                                 :count (- size content-start)
                                 :encoding :utf-8))
                       (trimmed (string-trim '(#\space #\tab #\newline) extract)))
                  (push (list delim-type
                              (if (eq delim-type :comment) nil trimmed)
                              next-delim size content-start size)
                        tokens)
                  (setf pos size)))))))))
    (nreverse tokens)))

