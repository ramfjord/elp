;;;; Tests for ELP/SERVER's default render handler.
;;;;
;;;; Drives the real HTTP server end-to-end (start acceptor on a test
;;;; port, drakma POST, stop). Coverage targets what's unique to
;;;; elp/server — source/param dispatch, body forwarding, error
;;;; translation — without re-pinning elp's own contract (which
;;;; source backends produce what output, what missing-kwarg errors
;;;; look like; those live in elp-test.lisp).

(defpackage :elp-server-test
  (:use :cl :fiveam)
  (:export :run-tests))

(in-package :elp-server-test)

(def-suite elp-server-suite :description "ELP/SERVER test suite")
(in-suite elp-server-suite)

(defparameter *test-port* 17890)
(defparameter *base-url* (format nil "http://localhost:~D/render" *test-port*))

(defmacro with-test-server (&body body)
  "Start a default-handler acceptor on *TEST-PORT* for BODY, stop it
   on exit (including unwind). One acceptor per test is fine — start
   is ~10ms."
  `(let ((acceptor (elp.server:start-render-server :port *test-port*)))
     (unwind-protect (progn ,@body) (hunchentoot:stop acceptor))))

(defun post (params)
  "POST PARAMS to the test server, return (values body-string status)."
  (multiple-value-bind (body status)
      (drakma:http-request *base-url* :method :post :parameters params)
    (values (if (stringp body) body (babel:octets-to-string body))
            status)))

(test default-handler-happy-path
  "Pins source/param dispatch and body forwarding: POST resolves SRC
   to a filepath-source, other params pass through as string-valued
   kwargs to the template, the handler's return value becomes the
   response body, status is 200."
  (with-test-server
    (uiop:with-temporary-file (:pathname p :type "elp")
      (with-open-file (f p :direction :output :if-exists :supersede)
        (write-string "Hi <%= name %>" f))
      (multiple-value-bind (body status)
          (post `(("src" . ,(namestring p)) ("name" . "Alice")))
        (is (= 200 status))
        (is (equal "Hi Alice" body))))))

(test default-handler-validation-error
  "Pins the elp/server-specific error path: handler's own
   validation (here: neither SRC nor TEXT supplied) signals, gets
   caught by the render route, returned as HTTP 500 with `ERR
   <message>` as body. Independent of elp's runtime-error contract."
  (with-test-server
    (multiple-value-bind (body status) (post '())
      (is (= 500 status))
      (is (search "src or text" body)))))

(defun run-tests ()
  (let ((results (run 'elp-server-suite)))
    (explain! results)
    (unless (results-status results)
      (uiop:quit 1))))
