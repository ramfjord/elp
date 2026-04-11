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
            (remaining-args (or args (rest (uiop:command-line-arguments)))))

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
          ;; Load context if provided
          (let ((context '()))
            (when context-file
              (with-open-file (f context-file)
                (loop for form = (read f nil nil)
                      while form do
                      (let ((val (eval form)))
                        ;; If it's a list of bindings, use it as context
                        (if (and (listp val) (listp (car val)))
                            (setf context val)
                            ;; Otherwise, it should be a single binding
                            (when val
                              (push val context)))))))

            ;; Render and output the template
            (let ((result (render-template template-file context)))
              (write-string result)))))

    (file-error (e)
      (format *error-output* "Error: ~A~%" e)
      (uiop:quit 1))
    (error (e)
      (format *error-output* "Error: ~A~%" e)
      (uiop:quit 1))))
