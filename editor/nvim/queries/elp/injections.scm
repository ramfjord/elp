; extends

; <% ... %> regions always inject Common Lisp.
((code) @injection.content
 (#set! injection.language "commonlisp")
 (#set! injection.combined))

; (content) regions inject whatever vim.b.elp_host says — set per
; buffer by ftplugin/elp.lua based on the filename. If no host is
; resolved, the directive is a no-op and the region stays uninjected.
((content) @injection.content
 (#elp-host!)
 (#set! injection.combined))
