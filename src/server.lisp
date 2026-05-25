;;;; Long-lived HTTP render daemon for ELP.
;;;;
;;;; Optional subsystem (ELP/SERVER) — only loaded by callers that ask
;;;; for it, so core ELP stays free of a Hunchentoot dependency.
;;;;
;;;; Two endpoints:
;;;;   POST /render — calls *RENDER-HANDLER*; its return value is the
;;;;                  response body. Any signaled condition becomes 500
;;;;                  with the condition message.
;;;;   GET  /health — calls *HEALTH-HANDLER*; default thunk returns "OK".
;;;;
;;;; Override either handler via SETF or LET on the exported var — the
;;;; easy-handler bodies read through the var at request time.

(defpackage :elp.server
  (:use :cl)
  (:export :start-render-server
           :*render-handler*
           :*health-handler*))

(in-package :elp.server)

(defun default-render-handler ()
  "Render the source named by SRC (filepath) or TEXT (literal),
   passing every other POST param through as a string-valued keyword
   to the template. Suits stateless one-shot rendering — callers that
   need richer scope (config loading, custom kwarg parsing) bind
   *RENDER-HANDLER* to their own thunk."
  (let* ((src  (hunchentoot:post-parameter "src"))
         (text (hunchentoot:post-parameter "text"))
         (source (cond
                   ((and src text) (error "src and text are mutually exclusive"))
                   (src  (elp:filepath-source (probe-file src)))
                   (text (elp:string-source text))
                   (t    (error "src or text is required"))))
         (kwargs (loop for (name . value) in (hunchentoot:post-parameters*)
                       unless (or (string= name "src") (string= name "text"))
                       collect (intern (string-upcase name) :keyword)
                       and collect value)))
    (with-output-to-string (out)
      (apply #'elp:render source out kwargs))))

(defvar *render-handler* #'default-render-handler
  "Thunk called by POST /render. Its return value becomes the response
   body. Any signaled condition translates to HTTP 500 with the
   condition message as body.

   Exposed as a dynamic variable so the HUNCHENTOOT:DEFINE-EASY-HANDLER
   body — which is defined at top-level and can't lexically capture
   runtime state — can read it at request time. Override via SETF for
   the process lifetime or LET around START-RENDER-SERVER for dynamic
   extent.")

(defvar *health-handler* (lambda () "OK")
  "Thunk called by GET /health; its return value is the response body.
   Override to gate readiness on project-specific state. Dynvar for
   the same reason as *RENDER-HANDLER* — see its docstring.")

(hunchentoot:define-easy-handler (render-route :uri "/render") ()
  (handler-case
      (or (funcall *render-handler*) "")
    (error (e)
      (setf (hunchentoot:return-code*) 500)
      (format nil "ERR ~A" e))))

(hunchentoot:define-easy-handler (health-route :uri "/health") ()
  (funcall *health-handler*))

(defun start-render-server (&rest acceptor-args &key &allow-other-keys)
  "Start a Hunchentoot acceptor and return it. The acceptor runs in
   its own thread; the caller keeps the image alive (typically
   `(loop (sleep most-positive-fixnum))`).

   All kwargs are forwarded to MAKE-INSTANCE on
   HUNCHENTOOT:EASY-ACCEPTOR — :port, :address, :taskmaster, etc.
   Defaults: port 7890, address 127.0.0.1, access/message logs off.

   To override the render or health handler, SETF or LET-bind
   *RENDER-HANDLER* or *HEALTH-HANDLER*."
  (hunchentoot:start
   (apply #'make-instance 'hunchentoot:easy-acceptor
          (append acceptor-args
                  '(:port 7890
                    :address "127.0.0.1"
                    :access-log-destination nil
                    :message-log-destination nil)))))
