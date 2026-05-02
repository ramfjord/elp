;;;; ELP Command-line interface

(defpackage :elp/cli
  (:use :cl :elp)
  (:export :main))

(in-package :elp/cli)

(defun print-usage ()
  (format t "Usage: elp [OPTIONS] TEMPLATE~%")
  (format t "~%")
  (format t "A fast template system for embedding Lisp code in text files.~%")
  (format t "~%")
  (format t "OPTIONS:~%")
  (format t "  -c, --context FILE    Load context variables from Lisp file~%")
  (format t "  -p, --print           Print the generated render code instead of evaluating it~%")
  (format t "  -h, --help            Show this help message~%")
  (format t "  -v, --version         Show version information~%")
  (format t "~%")
  (format t "TEMPLATE:~%")
  (format t "  Path to the template file to render~%")
  (format t "~%")
  (format t "SYNTAX:~%")
  (format t "  <%= expr %>   Output the value of expr~%")
  (format t "  <% code %>    Execute code without output~%"))

(defun main (&optional args)
  "Entry point for the ELP command-line tool.
   Accepts: template-file &optional context-file"
  (handler-case
      (let ((positional '())
            (context-file nil)
            (print-form nil)
            (remaining-args (or args (uiop:command-line-arguments))))

        ;; Parse arguments
        (loop while remaining-args do
          (let ((arg (pop remaining-args)))
            (cond
              ((member arg '("-h" "--help") :test #'string=)
               (print-usage)
               (uiop:quit 0))
              ((member arg '("-v" "--version") :test #'string=)
               (format t "elp 0.1.0~%")
               (uiop:quit 0))
              ((member arg '("-p" "--print") :test #'string=)
               (setf print-form t))
              ((member arg '("-c" "--context") :test #'string=)
               (setf context-file (pop remaining-args))
               (unless context-file
                 (format *error-output* "Error: --context requires an argument~%")
                 (uiop:quit 1)))
              (t
               (push arg positional)))))

        ;; Check for template file
        (unless positional
          (format *error-output* "Error: TEMPLATE argument required~%")
          (print-usage)
          (uiop:quit 1))

        (let ((template-file (car (reverse positional))))
          ;; Load context if provided. Forms are read as data — no EVAL —
          ;; so a literal alist `((name . "Alice") (age . 30))` works
          ;; without quoting, and an unwrapped `((foo))` doesn't get
          ;; misread as a function call. Each form may be either a full
          ;; alist (`((k . v) ...)`) or a single binding (`(k . v)`); the
          ;; shape decides whether to replace or push.
          (let ((context '()))
            (when context-file
              (with-open-file (f context-file)
                (loop for form = (read f nil nil)
                      while form do
                      (if (and (consp form) (consp (car form)))
                          (setf context form)
                          (push form context)))))

            (if print-form
                ;; Print the sexp that RENDER would EVAL. Binding *package*
                ;; to :ELP makes elp-internal symbols (helpers, *TEMPLATE-PTR*,
                ;; etc.) print unqualified, while CFFI/CL symbols stay
                ;; package-qualified — i.e. exactly what a reader would
                ;; want to copy/paste into an :ELP-using REPL.
                (let ((*print-pretty* t)
                      (*print-readably* nil)
                      (*package* (find-package :elp)))
                  (prin1 (function-lambda-expression
                          (compile-template (pathname template-file))))
                  (terpri))
                ;; Render the template, streaming output through *standard-output*.
                ;; In a saved binary, *standard-output* is an sb-sys:fd-stream, so
                ;; write-output-range fires its zero-copy write(2) path on the
                ;; mmap'd source instead of routing every text range through Lisp.
                (render (pathname template-file) context)))))

    (file-error (e)
      (format *error-output* "Error: ~A~%" e)
      (uiop:quit 1))
    (error (e)
      (format *error-output* "Error: ~A~%" e)
      (uiop:quit 1))))
