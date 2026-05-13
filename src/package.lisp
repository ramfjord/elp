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
   :open-source
   :close-source
   :with-open-source
   ;; Translation interface — materialized lambda-form text plus a
   ;; reversible doc-offset ↔ source-byte mapping for static analysis.
   ;; Two layers:
   ;;   OPEN-TEMPLATE   — bare emitter form (source-wrapped body +
   ;;                     handler-bind), free of any callable signature;
   ;;                     the LSP/analysis surface.
   ;;   CLOSED-TEMPLATE — composes an OPEN-TEMPLATE and adds the
   ;;                     callable (lambda (stream &key …)) wrapper
   ;;                     with supplied-p discipline; the render surface.
   ;; Shared protocol — TEMPLATE-TEXT, TEMPLATE-FORM, and the
   ;; DOC↔SOURCE generics work on either subclass.
   :template
   :template-text
   :template-form
   :translate-template
   :closed-template
   :closed-template-text
   :closed-template-open
   :translate-open
   :open-template
   :open-template-text
   :open-template-free-vars
   :doc-offset->source-byte
   :source-byte->doc-offset))
