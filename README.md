# ELP - Embedded LisP

A template system for Common Lisp that allows embedding Lisp code and expressions in text files, similar to ERB (Embedded Ruby).

## Syntax

- `<%= lisp-expression %>` — Evaluates the expression and outputs the result
- `<% lisp-code %>` — Executes Lisp code without producing output
- `<%# comment %>` — Comments (removed from output)

Tag contents are spliced raw into a single `(progn …)` body. Block forms
that span multiple tags must therefore include the opening paren in the
first tag and the closing paren in the last:

```erb
<% (when (> age 30) %>...<% ) %>
<% (dolist (path config-files) %>...<% ) %>
```

A `<%= … %>` tag emits `(format t "~A" <contents>)`, so the contents
must be a single Lisp form. `<%= (+ 1 2) %>` works; `<%= + 1 2 %>`
silently formats only `+` (printing `#<FUNCTION +>`) and discards
`1 2` as unused `format` arguments — no error, just wrong output.
Tracked as a known sharp edge in
[#9](https://github.com/ramfjord/elp/issues/9).

### Whitespace trim

Per-tag opt-in trimming, matching ERB's `-` flag:

- `-%>` — at the close, drop a single trailing line break (`\r?\n`)
  immediately after the delimiter.
- `<%-`, `<%-=`, `<%-#` — at the open, strip ASCII spaces and tabs
  immediately *preceding* the delimiter back to (but keeping) the
  prior newline. If anything non-whitespace shares the line, no
  stripping happens.

Plain `<% %>` and `<%= %>` are unchanged.

The combined form makes multi-tag block constructs render cleanly:

```erb
<% (dolist (x xs) -%>
  - <%= x %>
<%- ) -%>
```

with `xs = (a b c)` renders as:

```
  - a
  - b
  - c
```

Caveat: as with bare `%>`, `-%>` inside a Lisp string literal (e.g.
`<% (format t "-%>") %>`) still ends the tag — the engine does not
track reader state when scanning for the close.

## Usage

### Basic Example - Render from File

```lisp
(use-package :elp)

(render #p"template.elp"
  '((name . "Alice")
    (age . 30)))
;; Writes to *standard-output*: Hello Alice, you are 30 years old.
```

Where `template.elp` contains:
```erb
Hello <%= name %>, you are <%= age %> years old.
```

### With Conditionals

`template.elp`:
```erb
Name: <%= name %><% (when (> age 30) %> (senior)<% ) %>
```

```lisp
(render #p"template.elp"
  '((name . "Bob")
    (age . 35)))
;; Writes to *standard-output*: Name: Bob (senior)
```

### Using with Full Lisp Power

Since the template has access to full Common Lisp, you can use any Lisp functions:

```erb
[Unit]
Description=<%= desc %> (<%= name %>)
<% (dolist (path config-files) %>
PathChanged=<%= path %>
<% ) %>
```

```lisp
(render #p"systemd-unit.elp"
  '((desc . "My Service")
    (name . "myapp")
    (config-files . ("/etc/myapp/config.yml"
                     "/etc/myapp/secrets.env"))))
```

### Compile Once, Render Many

For repeated renders of the same template (e.g. an HTTP handler that
fills the same page on every request), compile once and reuse the
returned `compiled-template`:

```lisp
(use-package :elp)

(defparameter *page* (compile-template #p"page.elp"))

(funcall *page* '((name . "Alice"))
                 *standard-output*)
;; or equivalently:
(render *page* '((name . "Alice")))
(render *page* '((name . "Bob")))
```

`compile-template` parses the template once and returns a
funcallable instance carrying the compiled render code plus source
metadata. Subsequent calls skip the read and codegen pass — only
the body runs. The same instance is safe to reuse with different
context-alists.

`render` accepts either a pathname (compiles on every call) or a
`compiled-template` (renders against the precompiled code). See
issue #8 for the design rationale.

## Context Variables

Variables are passed as an association list (alist) where keys become symbols available in the template:

```lisp
'((service-name . "radarr")
  (port . 7878)
  (enabled . t))
```

Inside templates, reference them directly:
```erb
Name: <%= service-name %>
Port: <%= port %>
<% (when enabled %>
Active
<% ) %>
```

## API

### Public API

**`(render input context-alist &optional stream)`**

Renders a template, streaming output bytes directly to `stream`
(defaults to `*standard-output*`). Output is produced as bytes are
generated, with no intermediate Lisp string. When `stream` is an
`sb-sys:fd-stream` (e.g. the CLI's `*standard-output*` in a saved
binary), literal text ranges are written via a single `write(2)`
syscall directly on the mmap'd source — zero copy through Lisp.

- `input`: A pathname (compiled and rendered in one step) or a
  `compiled-template` from `compile-template`
- `context-alist`: List of `(symbol . value)` pairs
- `stream`: Destination stream (default: `*standard-output*`)
- Returns: no useful value; consumers care about side effects on `stream`

For callers that want the output as a string, wrap in
`with-output-to-string`:

```lisp
(with-output-to-string (s)
  (render #p"template.elp" '((name . "Alice")) s))
```

**`(compile-template pathname)` → `compiled-template`**

Compiles the template at `pathname` once and returns a funcallable
instance carrying the compiled render function plus source metadata.
The instance is `funcall`-able as `(funcall tmpl ctx)` or `(funcall
tmpl ctx stream)`, and `render` accepts it as `input`. Reusing the
same instance across calls with different context-alists is the
intended path for hot rendering loops.

Template variables not present in the context-alist bind to `NIL`
silently — the runtime lookup is `(cdr (assoc 'sym ctx))`. If you
need stricter behavior, validate the context-alist in your caller.

**`(compiled-template-source-pathname tmpl)` / `(compiled-template-compiled-at tmpl)`**

Readers on a `compiled-template` for the originating pathname (or
`NIL`) and the `get-universal-time` value at compile time.

### Errors

**`elp-template-error`**

Errors signaled during template read or rendering are translated to an
`elp-template-error` condition with readers `elp-template-error-file`,
`elp-template-error-line`, `elp-template-error-column`, and
`elp-template-error-original`.

## Features

- Full Common Lisp access (no restricted DSL)
- Simple syntax familiar to ERB users
- Supports loops, conditionals, function calls, etc.
- Byte-position tracking for error reporting

## Installation

Add to your ASDF system dependencies:

```lisp
(defsystem "my-project"
  :depends-on ("elp")
  ...)
```

Or load directly:

```lisp
(asdf:load-system :elp)
```

## Implementation Notes

- The template file is `mmap`'d once. The mapping is wrapped in a
  custom Gray input stream (`template-stream`) that the standard Lisp
  reader walks directly. Literal text spans are located via libc
  `memmem`; only the bytes inside `<% ... %>` blocks are handed to the
  reader as characters, plus a small synthesized prefix/suffix per
  block. The file is never slurped into a Lisp string.
- For each text span, the stream synthesizes a single
  `(elp::write-output-range *template-ptr* START END)` call that, at
  render time, writes those bytes straight from the mapping. When the
  destination is an `sb-sys:fd-stream` (e.g. the CLI's stdout in a
  saved binary), this is a single `write(2)` syscall on the mapped
  pages — zero copy through Lisp.
- The standard reader builds the body sexp directly from the stream;
  there is no intermediate source-string assembly and no separate
  tokenizer phase. Multi-block constructs like
  `<% (dolist ... %> body <% ) %>` work because the reader is in the
  middle of building a list when the stream transitions through `%>
  ... text ... <%`, and the synthesized text-emit forms are appended
  to the in-progress list.
- A `position-map` on the stream records `(reader-position .
  mmap-byte)` checkpoints at the start of each code or expression
  body. Reader errors are translated into `elp-template-error` with
  `file:line:column` by mapping the reader's stop position to a source
  byte and counting newlines in the prefix via libc `memchr` — the
  prefix scan is vectorized rather than per-byte.

