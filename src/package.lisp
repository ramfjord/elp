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
   ;; Source protocol — abstract SOURCE with two concrete backends.
   ;; Backend class names double as constructors:
   ;;   (mmap-source path)             — mmap, size > 0
   ;;   (string-source text &key name) — Lisp-string backed
   ;; FILEPATH-SOURCE is the convenience dispatcher: takes a
   ;; pathname and returns either an MMAP-SOURCE or, for empty
   ;; files, a STRING-SOURCE of "".
   :source
   :mmap-source
   :string-source
   :filepath-source
   :source-name
   :close-source
   ;; Translation interface — materialized lambda-form text plus a
   ;; reversible doc-offset ↔ source-byte mapping for static analysis.
   :translate-template
   :translated-template
   :translated-template-text
   :doc-offset->source-byte
   :source-byte->doc-offset))
