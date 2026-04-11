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

   Tokenizes the template file, generates executable Lisp code, and evaluates it
   with the provided context bindings, returning the rendered output."
  (let ((tokens (tokenize-file pathname)))
    (let ((sexp (generate-render-code pathname tokens context-alist)))
      (with-output-to-string (out)
        (let ((*standard-output* out))
          (eval sexp))))))

;;;; Internal Helper Functions

(defun write-output-range (filename start end &optional (stream *standard-output*))
  "Write bytes from START to END of FILENAME to STREAM.

   Uses buffered reading to avoid loading the entire range into memory at once.
   Buffer size is 8KB for efficient streaming of large template sections."
  (with-open-file (f filename :direction :input :element-type 'character)
    (let ((buffer-size 8192)
          (remaining (- end start)))
      (file-position f start)
      (loop while (> remaining 0)
            do (let* ((to-read (min buffer-size remaining))
                      (buf (make-string to-read)))
                 (read-sequence buf f)
                 (write-string buf stream)
                 (decf remaining to-read))))))

(defun generate-render-code (filename tokens &optional context-alist)
  "Generate executable Lisp code from tokenized template.
   Returns an S-expression that renders the template when executed.

   Optional context-alist is a list of (symbol . value) pairs that will be bound
   as variables available to expressions in the template.

   Note: Currently only supports code blocks that fit within a single delimiter pair.
   Multi-token code structures (like loops spanning delimiters) are not yet supported."
  (let ((code-parts '()))
    ;; Process each token and build code fragments
    (dolist (token tokens)
      (let ((type (first token))
            (content (second token))
            (start (third token))
            (end (fourth token)))
        (case type
          (:text
           ;; Text becomes a write-output-range call
           (push (list 'write-output-range filename start end) code-parts))
          (:expr
           ;; Expression: evaluate and write result to stream
           (if (zerop (length (string-trim '(#\space #\tab #\newline) content)))
               ;; Empty expression outputs nothing
               nil
               (let ((expr-form (read-from-string content)))
                 (push (list 'format 't "~A" expr-form) code-parts))))
          (:code
           ;; Code: read it as a form and include it
           (push (read-from-string content) code-parts))
          (:comment
           ;; Comments are ignored
           nil))))

    ;; Build bindings from context-alist
    (let ((bindings (mapcar (lambda (binding)
                              (list (car binding) `',(cdr binding)))
                            context-alist)))
      ;; Wrap all parts in a progn, optionally wrapped in let
      (let ((progn-form (cons 'progn (nreverse code-parts))))
        (if bindings
            `(let ,bindings ,progn-form)
            progn-form)))))

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
