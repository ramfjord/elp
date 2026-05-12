;;;; Source protocol + concrete backends (MMAP-SOURCE, STRING-SOURCE).
;;;;
;;;; A SOURCE is whatever the template engine scans / reads / writes
;;;; bytes from. The TEMPLATE-BODY-STREAM state machine in elp.lisp drives
;;;; the protocol generically — same code, two backends.
;;;;
;;;; The protocol is six generics:
;;;;
;;;;   SOURCE-LENGTH         byte count
;;;;   SOURCE-BYTE           byte at offset (as integer 0..255)
;;;;   SOURCE-SEARCH         memmem-shape — offset of needle from START
;;;;   SOURCE-SUBSTRING      bytes [START, END) as a Lisp string
;;;;   SOURCE-LINE+COLUMN    (values LINE COL) at a given source byte
;;;;   SOURCE-EMIT-TEXT-FORM Lisp source — one form — that writes the
;;;;                         source bytes [START, END) to
;;;;                         *standard-output* at render time. Must
;;;;                         agree with SOURCE-WRAP-LAMBDA-BODY on what
;;;;                         lexicals the emitted form references.
;;;;   SOURCE-WRAP-LAMBDA-BODY  Wrap a template lambda's protected
;;;;                         form in whatever bindings + cleanup this
;;;;                         source needs. Default: identity.
;;;;
;;;; Plus SOURCE-NAME and CLOSE-SOURCE.
;;;;
;;;; Construction: backend-named constructors share their symbols
;;;; with their class names (function vs. class namespaces are
;;;; separate in CL). `(mmap-source #P"foo.elp")` opens the mmap and
;;;; returns a fresh instance; `(string-source "...")` wraps a string.
;;;; FILEPATH-SOURCE is the convenience dispatcher: takes a pathname
;;;; and returns either an MMAP-SOURCE or (for size=0 files, which
;;;; mmap rejects with EINVAL) a STRING-SOURCE of "".

(in-package :elp)

;;;; ============================================================
;;;; Foreign-memory primitives — used by MMAP-SOURCE's methods and by
;;;; the runtime WRITE-OUTPUT-RANGE that MMAP-SOURCE-EMIT-TEXT-FORM
;;;; emits a call to.

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

(defun %byte-at (ptr offset)
  (cffi:mem-aref (cffi:inc-pointer ptr offset) :unsigned-char 0))

(defun mmap-substring (ptr start end)
  "Materialize the mmap byte range [START, END) as a Lisp string,
   one char per byte (Latin-1 mapping)."
  (cffi:foreign-string-to-lisp (cffi:inc-pointer ptr start)
                               :count (- end start)
                               :encoding :latin-1))

;;;; ============================================================
;;;; Abstract base class — gives the protocol generics a real
;;;; specializer to document against, and gives callers a single type
;;;; to declare for "any source" (e.g. FILEPATH-SOURCE's return).

(defclass source () ()
  (:documentation
   "Abstract base for ELP input sources. Concrete backends —
    MMAP-SOURCE, STRING-SOURCE — inherit from this. The protocol
    generics (SOURCE-LENGTH, SOURCE-BYTE, SOURCE-SEARCH, …) dispatch
    on subclasses."))

;;;; ============================================================
;;;; Protocol generics. Method specializers determine dispatch; the
;;;; docstrings describe expected argument/return types. (Generics
;;;; manage their own FTYPE — DECLAIMing on a generic is overwritten
;;;; by DEFGENERIC.)

(defgeneric source-length (source)
  (:documentation "Return the byte length of SOURCE as a non-negative integer."))

(defgeneric source-byte (source offset)
  (:documentation "Return the byte at OFFSET in SOURCE as an integer 0..255."))

(defgeneric source-search (source needle start)
  (:documentation
   "Return the offset of NEEDLE (an ASCII string) in SOURCE at or
    after START, or NIL if not present."))

(defgeneric source-substring (source start end)
  (:documentation "Return SOURCE bytes [START, END) as a Lisp string."))

(defgeneric source-line+column (source byte-offset)
  (:documentation
   "Return (values LINE COL) — both 1-based — for BYTE-OFFSET in
    SOURCE. ASCII column semantics."))

(defgeneric source-name (source)
  (:documentation
   "Return a display name for SOURCE — typically a pathname for
    MMAP-SOURCE, a caller-supplied string for STRING-SOURCE."))

(defgeneric source-emit-text-form (source start end)
  (:documentation
   "Return a STRING of Lisp source — one form — that writes the
    source bytes [START, END) to *standard-output* at render time.
    Must agree with SOURCE-WRAP-LAMBDA-BODY on what lexicals the
    emitted form references."))

(defgeneric source-wrap-lambda-body (source body)
  (:documentation
   "Wrap BODY (a sexp containing the rendered template body forms,
    including HANDLER-BIND and supplied-p checks) in whatever
    bindings + cleanup this source needs at render time. The
    wrapped form sits inside (let ((*standard-output* stream)) ...)
    in the compiled lambda.")
  (:method ((s t) body) body))

(defgeneric close-source (source)
  (:documentation
   "Release any OS resources the source holds. Idempotent — calling
    twice on the same source is safe. STRING-SOURCE uses the default
    no-op method; MMAP-SOURCE unmaps and closes the underlying fd.")
  (:method ((s t)) (declare (ignore s)) nil))

;;;; ============================================================
;;;; mmap-source — foreign-memory backed, the fast path for file
;;;; rendering. Render codegen does zero-copy WRITE(2) on the mapped
;;;; region via WRITE-OUTPUT-RANGE.

(defclass mmap-source (source)
  ((ptr      :initarg :ptr      :accessor mmap-source-ptr)
   (size     :initarg :size     :accessor mmap-source-size)
   (fd       :initarg :fd       :accessor mmap-source-fd)
   (pathname :initarg :pathname :reader   mmap-source-pathname))
  (:documentation
   "Source backed by a memory-mapped file. Construct via (MMAP-SOURCE
    pathname); release via (CLOSE-SOURCE source). CLOSE-SOURCE is
    idempotent — sets the mmap slots to NIL after unmapping.

    PATHNAME must point to a regular file of size > 0; %mmap-open(2)
    rejects size=0 with EINVAL. Use FILEPATH-SOURCE for the
    convenience path that dispatches to STRING-SOURCE on empty
    files."))

(declaim (ftype (function (pathname) mmap-source) mmap-source))
(defun mmap-source (pathname)
  "Open PATHNAME read-only, mmap it, and return a fresh MMAP-SOURCE.
   PATHNAME must have size > 0 — see the class docstring for the
   rationale; FILEPATH-SOURCE handles the size=0 case.

   Caller (or downstream consumer) is responsible for CLOSE-SOURCE.
   COMPILE-TEMPLATE, RENDER, and TRANSLATE-TEMPLATE all close the
   source after consuming it, so most callers don't need to manage
   the lifecycle explicitly."
  (multiple-value-bind (ptr size fd) (%mmap-open pathname)
    (make-instance 'mmap-source
                   :ptr ptr :size size :fd fd :pathname pathname)))

(declaim (ftype (function (pathname) source) filepath-source))
(defun filepath-source (pathname)
  "Open PATHNAME and return a SOURCE for its contents. Returns a
   STRING-SOURCE of \"\" for empty files (mmap rejects size=0 with
   EINVAL), an MMAP-SOURCE otherwise. Callers should treat the
   result as an abstract SOURCE — use the protocol generics, not
   backend-specific accessors."
  (if (zerop (with-open-file (f pathname) (file-length f)))
      (string-source "" :name pathname)
      (mmap-source pathname)))

(defmethod close-source ((s mmap-source))
  (when (mmap-source-ptr s)
    (%mmap-close (mmap-source-ptr s)
                 (mmap-source-size s)
                 (mmap-source-fd s))
    (setf (mmap-source-ptr s) nil
          (mmap-source-size s) nil
          (mmap-source-fd s)   nil)))

(defmethod source-length ((s mmap-source))
  (mmap-source-size s))

(defmethod source-byte ((s mmap-source) offset)
  (%byte-at (mmap-source-ptr s) offset))

(defmethod source-search ((s mmap-source) needle start)
  (let* ((ptr  (mmap-source-ptr s))
         (size (mmap-source-size s))
         (rel  (%memmem (cffi:inc-pointer ptr start)
                        (- size start) needle)))
    (and rel (+ start rel))))

(defmethod source-substring ((s mmap-source) start end)
  (mmap-substring (mmap-source-ptr s) start end))

(defmethod source-line+column ((s mmap-source) byte-offset)
  (let* ((ptr        (mmap-source-ptr s))
         (size       (mmap-source-size s))
         (target     (min byte-offset size))
         (line       1)
         (line-start 0)
         (cursor     0))
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

(defmethod source-name ((s mmap-source))
  (mmap-source-pathname s))

(defmethod source-emit-text-form ((s mmap-source) start end)
  ;; Zero-copy: references elp::ptr bound by SOURCE-WRAP-LAMBDA-BODY.
  (format nil "(elp::write-mmap-range elp::ptr ~D ~D) " start end))

(defmethod source-wrap-lambda-body ((s mmap-source) body)
  ;; Bind PTR/SIZE/FD lexicals the body's WRITE-OUTPUT-RANGE calls
  ;; reference. Also bind a fresh runtime MMAP-SOURCE at SOURCE so the
  ;; handler-bind in BUILD-TEMPLATE-LAMBDA can dispatch
  ;; SOURCE-LINE+COLUMN / SOURCE-NAME generically.
  (let ((pathname (mmap-source-pathname s)))
    `(multiple-value-bind (elp::ptr elp::size elp::fd)
         (elp::%mmap-open ,pathname)
       (let ((elp::source
              (make-instance 'elp::mmap-source
                             :ptr elp::ptr :size elp::size :fd elp::fd
                             :pathname ,pathname)))
         (unwind-protect ,body
           (elp::%mmap-close elp::ptr elp::size elp::fd))))))

;;;; ============================================================
;;;; string-source — Lisp-string backed. No runtime acquisition cost.
;;;; Render codegen inlines string literals into the compiled lambda
;;;; — no source lexical needed at render time.

(defclass string-source (source)
  ((text :initarg :text :reader string-source-text)
   (name :initarg :name :initform "<string>" :reader string-source-name))
  (:documentation
   "Source backed by a Lisp string. Construct via (STRING-SOURCE text
    &key name). CLOSE-SOURCE is a no-op."))

(declaim (ftype (function (string &key (:name t)) string-source) string-source))
(defun string-source (text &key (name "<string>"))
  "Wrap TEXT in a STRING-SOURCE. NAME (default \"<string>\") is the
   display name used in error messages."
  (make-instance 'string-source :text text :name name))

(defmethod source-length ((s string-source))
  (length (string-source-text s)))

(defmethod source-byte ((s string-source) offset)
  (char-code (char (string-source-text s) offset)))

(defmethod source-search ((s string-source) needle start)
  (search needle (string-source-text s) :start2 start))

(defmethod source-substring ((s string-source) start end)
  (subseq (string-source-text s) start end))

(defmethod source-line+column ((s string-source) byte-offset)
  (let* ((text (string-source-text s))
         (target (min byte-offset (length text)))
         (line 1)
         (line-start 0))
    (dotimes (i target)
      (when (char= (char text i) #\Newline)
        (incf line)
        (setf line-start (1+ i))))
    (values line (1+ (- target line-start)))))

(defmethod source-name ((s string-source))
  (string-source-name s))

(defmethod source-emit-text-form ((s string-source) start end)
  ;; Inline the literal — no runtime source binding needed.
  ;; ~S quotes the string properly (handles embedded ", \, newlines).
  (format nil "(write-string ~S) "
          (subseq (string-source-text s) start end)))

;; SOURCE-WRAP-LAMBDA-BODY: default no-op method applies — the emitted
;; text forms are self-contained.
;; CLOSE-SOURCE: default no-op method applies.
