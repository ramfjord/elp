((code) @injection.content
 (#set! injection.language "commonlisp")
 (#set! injection.combined))

; The host language for `(content)` is per-file (e.g. Makefile.elp →
; make, service.yml.elp → yaml). The editor sets it dynamically; no
; static injection here.
