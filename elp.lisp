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
   ;; Advanced/internal-use API
   :tokenize-file))


(in-package :elp)

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

;;;; Public API

(defgeneric render (input context)
  (:documentation "Render a template from INPUT with CONTEXT variable bindings.

   INPUT must be a pathname (file path). The template file is rendered
   efficiently by reading directly from the file without loading it entirely
   into memory.

   CONTEXT is an alist of (symbol . value) pairs that will be available
   as variables in template expressions.

   Returns the rendered output as a string."))

(defmethod render ((pathname pathname) context-alist)
  "Render template file at PATHNAME with CONTEXT-ALIST.

   Tokenizes the file, generates a self-contained sexp that opens the mmap,
   writes all text ranges via write(2), then closes it, and evals that sexp."
  (let* ((tokens (tokenize-file pathname))
         (sexp   (generate-render-code pathname tokens context-alist)))
    (with-output-to-string (out)
      (let ((*standard-output* out))
        (eval sexp)))))

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

(defun generate-render-code (pathname tokens &optional context-alist)
  "Generate a self-contained executable sexp from PATHNAME and its TOKENS.

   The returned sexp opens the file via mmap, writes all text ranges directly
   from the mapped memory, evaluates expressions and code blocks, then unmaps
   the file — all within an unwind-protect so the file is always closed.

   CONTEXT-ALIST is a list of (symbol . value) pairs bound as variables
   available to template expressions.

   Note: Currently only supports code blocks that fit within a single delimiter
   pair.  Multi-token code structures (like loops spanning delimiters) are not
   yet supported."
  (let ((code-parts '()))
    ;; Process each token and build code fragments
    (dolist (token tokens)
      (let ((type (first token))
            (content (second token))
            (start (third token))
            (end (fourth token)))
        (case type
          (:text
           ;; Text becomes a write-output-range call; ptr is the lexical
           ;; variable bound by the mmap multiple-value-bind below.
           (push `(elp::write-output-range ptr ,start ,end) code-parts))
          (:expr
           (unless (zerop (length (string-trim '(#\space #\tab #\newline) content)))
             (push `(format t "~A" ,(read-from-string content)) code-parts)))
          (:code
           (push (read-from-string content) code-parts))
          (:comment nil))))

    ;; Build context let-bindings
    (let* ((bindings  (mapcar (lambda (b) `(,(car b) ',(cdr b))) context-alist))
           (body      (cons 'progn (nreverse code-parts)))
           (body-with-context (if bindings `(let ,bindings ,body) body)))
      ;; Wrap everything in the mmap open/close lifecycle
      `(multiple-value-bind (ptr size fd) (elp::%mmap-open ,pathname)
         (unwind-protect
             ,body-with-context
           (elp::%mmap-close ptr size fd))))))

(defun tokenize-file (filename)
  "Stream template file and yield tokens."
  (unless (probe-file filename)
    (error "File not found: ~A" filename))

  (let ((content (with-open-file (f filename :direction :input)
                   (let ((str (make-string (file-length f))))
                     (read-sequence str f)
                     str)))
        (tokens '())
        (pos 0)
        (depth 0))

    (loop while (< pos (length content))
          do
      (let ((comment-pos (search "<%#" content :start2 pos))
            (expr-pos (search "<%=" content :start2 pos))
            (code-pos (search "<%"  content :start2 pos)))

        ;; Find next delimiter (prioritize <%# then <%= then <%)
        (let ((next-delim nil)
              (delim-type nil)
              (delim-len nil))

          (when comment-pos
            (setf next-delim comment-pos delim-type :comment delim-len 3))
          (when (and expr-pos (or (not comment-pos) (< expr-pos comment-pos)))
            (setf next-delim expr-pos delim-type :expr delim-len 3))
          (when (and code-pos (or (not comment-pos) (< code-pos comment-pos))
                               (or (not expr-pos) (< code-pos expr-pos)))
            (setf next-delim code-pos delim-type :code delim-len 2))

          (if (not next-delim)
              ;; No delimiter found, rest is text
              (progn
                (when (< pos (length content))
                  (push (list :text (subseq content pos) pos (length content) depth) tokens))
                (setf pos (length content)))
              ;; Found delimiter
              (progn
                ;; Add text before delimiter if any
                (when (< pos next-delim)
                  (push (list :text (subseq content pos next-delim) pos next-delim depth) tokens))

                ;; Find closing %>
                (let ((content-start (+ next-delim delim-len))
                      (close-pos (search "%>" content :start2 (+ next-delim delim-len))))

                  (if close-pos
                      ;; Found closing delimiter
                      (let ((token-content (string-trim '(#\space #\tab #\newline) (subseq content content-start close-pos)))
                            (token-end (+ close-pos 2)))
                        (push (list delim-type token-content next-delim token-end depth) tokens)
                        ;; Update depth for code tokens
                        (when (eq delim-type :code)
                          (let ((opens 0) (closes 0))
                            (loop for ch across token-content
                                  do (cond ((member ch '(#\( #\[ #\{)) (incf opens))
                                           ((member ch '(#\) #\] #\})) (incf closes))))
                            (setf depth (+ depth (- opens closes)))))
                        (setf pos token-end))
                      ;; No closing delimiter
                      (let ((token-content (string-trim '(#\space #\tab #\newline) (subseq content content-start))))
                        (push (list delim-type token-content next-delim (length content) depth) tokens)
                        (setf pos (length content))))))))))

    (nreverse tokens)))

(defun split-string (string delimiter)
  "Split a string by a delimiter and return a list of substrings.
   Example: (split-string \"a-b-c\" \"-\") => (\"a\" \"b\" \"c\")"
  (let ((result '())
        (current-pos 0)
        (delim-len (length delimiter)))
    (loop
      (let ((pos (search delimiter string :start2 current-pos)))
        (if pos
            (progn
              (push (subseq string current-pos pos) result)
              (setf current-pos (+ pos delim-len)))
            (progn
              (push (subseq string current-pos) result)
              (return)))))
    (nreverse result)))

(defun find-closing-bracket (string start-pos)
  "Find the position of the closing %> starting from start-pos."
  (search "%>" string :start2 start-pos))

(defun parse-template (template-string)
  "Parse template into list of (type . content) pairs.
   type is :text, :expr, or :code
   For :expr and :code, content is the Lisp expression/code as a string."
  (let ((result '())
        (pos 0)
        (len (length template-string)))
    (do ()
        ((>= pos len))
      (let ((expr-start (search "<%=" template-string :start2 pos))
            (code-start (search "<%"  template-string :start2 pos)))
        (let ((next-start (cond
                            ((and expr-start code-start) (min expr-start code-start))
                            (expr-start expr-start)
                            (code-start code-start)
                            (t nil))))
          (if (null next-start)
              (progn
                (when (< pos len)
                  (push (cons :text (subseq template-string pos)) result))
                (setf pos len))
              (progn
                (when (< pos next-start)
                  (push (cons :text (subseq template-string pos next-start)) result))

                (if (and expr-start (= next-start expr-start))
                    (let ((content-start (+ expr-start 3)))
                      (let ((close-pos (find-closing-bracket template-string content-start)))
                        (if close-pos
                            (let ((content (subseq template-string content-start close-pos)))
                              (push (cons :expr content) result)
                              (setf pos (+ close-pos 2)))
                            (error "Unclosed <%= in template"))))
                    (let ((content-start (+ code-start 2)))
                      (let ((close-pos (find-closing-bracket template-string content-start)))
                        (if close-pos
                            (let ((content (subseq template-string content-start close-pos)))
                              (push (cons :code content) result)
                              (setf pos (+ close-pos 2)))
                            (error "Unclosed <% in template"))))))))))
    (nreverse result)))

(defun render-template (filename context-alist)
  "Render a template file with the given context (association list of variable bindings).
   Returns the rendered string."
  (let ((template-string (with-open-file (f filename :direction :input)
                           (let ((contents (make-string (file-length f))))
                             (read-sequence contents f)
                             contents))))
    (render-string template-string context-alist)))

(defun render-string (template-string context-alist)
  "Render a template string with the given context.
   context-alist is a list of (symbol . value) pairs."
  (let ((parsed (parse-template template-string))
        (output '())
        (code-forms '()))

    ;; Build list of code forms to evaluate
    (dolist (binding context-alist)
      (let ((var (car binding))
            (val (cdr binding)))
        (push `(,var ',val) code-forms)))

    ;; Add output accumulator
    (push '(output '()) code-forms)

    ;; Build forms to execute from parsed template
    (dolist (element parsed)
      (let ((type (car element))
            (content (cdr element)))
        (case type
          (:text (push `(push ,content output) code-forms))
          (:expr (let ((expr-form (read-from-string content)))
                   (push `(push (format nil "~A" ,expr-form) output) code-forms)))
          (:code (let ((code-form (read-from-string (concatenate 'string "progn " content))))
                   (push code-form code-forms)))
          (otherwise nil))))

    ;; Add final result form
    (push '(apply #'concatenate 'string (reverse output)) code-forms)

    ;; Execute all forms and return result
    (eval `(let ,(nreverse code-forms)
             (apply #'concatenate 'string (reverse output))))))
