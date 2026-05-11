;;;; ELP package definition. Kept in its own file so SOURCE.LISP can
;;;; (in-package :elp) before the main engine file loads.

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
   :elp-template-error-original
   ;; Embedded-language helpers — for tools that want only the code
   :code-byte-ranges
   :extract-code-text
   ;; Source protocol — mmap-backed or string-backed input
   :mmap-source
   :string-source
   :source-name
   ;; Stream interface — full lambda-form character stream with
   ;; source-byte round-trip for the body bytes
   :open-template-stream-from-file
   :open-template-stream-from-string
   :stream-byte-position
   :template-stream
   :template-lambda-stream))
