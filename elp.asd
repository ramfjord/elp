;;;; elp.asd - ASDF system definition for ELP (Embedded Lisp Pages)

(defsystem "elp"
  :description "A fast template system for embedding Lisp code in text files"
  :version "0.1.0"
  :author "Thomas Ramfjord"
  :license "MIT"
  :homepage "https://github.com/thomasramfjord/mediaserver"
  :source-control (:git "https://github.com/thomasramfjord/mediaserver")
  :depends-on ("alexandria" "cffi" "cl-ppcre" "hu.dwim.walker")
  :components
  ((:file "elp")
   (:file "cli" :depends-on ("elp")))
  :in-order-to ((test-op (test-op "elp/tests"))))

(defsystem "elp/tests"
  :description "Tests for ELP"
  :depends-on ("elp" "fiveam")
  :components
  ((:file "elp-test"))
  :perform (test-op (op c)
             (uiop:symbol-call :elp-test :run-tests)))
