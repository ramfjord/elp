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

(render (filepath-source #p"template.elp") *standard-output*
        :name "Alice" :age 30)
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
(render (filepath-source #p"template.elp") *standard-output*
        :name "Bob" :age 35)
;; Writes to *standard-output*: Name: Bob (senior)
```

### Render from a String

Useful for buffer-backed input (e.g. an LSP) or programmatically
built templates — no on-disk file required:

```lisp
(render (string-source "Hi <%= name %>") *standard-output*
        :name "Alice")
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
(render (filepath-source #p"systemd-unit.elp") *standard-output*
        :desc "My Service"
        :name "myapp"
        :config-files '("/etc/myapp/config.yml"
                        "/etc/myapp/secrets.env"))
```

### Compile Once, Render Many

For repeated renders of the same template (e.g. an HTTP handler that
fills the same page on every request), compile once and reuse the
returned function:

```lisp
(use-package :elp)

(defparameter *page*
  (compile-template (filepath-source #p"page.elp")))

(funcall *page* *standard-output* :name "Alice")
(funcall *page* *standard-output* :name "Bob")
```

`compile-template` parses the template once and returns a function
of `(stream &key var-1 var-2 … &allow-other-keys)`. The source is
closed after compilation; the returned function is self-contained
(mmap-source's wrap re-opens the mmap at render time). Each free
template variable is one keyword parameter; missing keys signal
`elp-template-error` at the reference site. Extra keyword arguments
are silently ignored, so callers can pass a comprehensive bag of
bindings and let each template pick the subset it needs.

## Sources

`render`, `compile-template`, and `translate-template` all take a
**source** — an object that knows where to find the template bytes.
Two backends, plus a path-dispatching convenience:

```lisp
(filepath-source #p"path/to/file.elp")    ; mmap-source for regular files,
                                          ; string-source "" for size=0
(mmap-source #p"non-empty.elp")           ; mmap-backed directly (size > 0)
(string-source "template text"
               :name "buffer.elp")        ; Lisp-string-backed
```

Most callers reach for `filepath-source` when they have a path on
disk: it returns an `mmap-source` for the common case and
short-circuits to a `string-source` of `""` for empty files (which
`mmap(2)` rejects with `EINVAL`). `mmap-source` is the bare backend
constructor — useful when you already know the file is non-empty.

A source is consumed by whichever entry point takes it (closed
automatically). For long-lived use (compile-once render-many),
`compile-template` returns a reusable function; the source itself is
released as part of compilation.

## Context Variables

Variables are passed as keyword arguments matching the template's
free symbols. The compiled template's signature is
`(stream &key VAR1 VAR2 … &allow-other-keys)`, so anything `&key`
accepts works:

```lisp
(render (filepath-source #p"unit.elp") *standard-output*
        :service-name "radarr"
        :port 7878
        :enabled t)
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

**`(render source stream &rest kwargs)`**

Compiles and renders `source` to `stream` with `kwargs` as the
template's free-variable bindings. Output bytes go to `stream`
as they are produced — no intermediate Lisp string. When `stream`
is an `sb-sys:fd-stream` (e.g. the CLI's `*standard-output*` in a
saved binary) *and* `source` is an `mmap-source`, literal text
ranges write via a single `write(2)` syscall directly on the
mmap'd region — zero copy through Lisp.

- `source`: an `mmap-source` or `string-source` (typically built via
  `filepath-source` or `string-source`). Consumed
  (`close-source`'d) as part of compilation.
- `stream`: Destination stream.
- `kwargs`: `&rest` plist passed through to the compiled template's
  `&key` parameters.

For callers that want the output as a string, wrap in
`with-output-to-string`:

```lisp
(with-output-to-string (s)
  (render (filepath-source #p"template.elp") s :name "Alice"))
```

**`(compile-template source)` → function**

Compiles `source` once and returns a function of
`(stream &key var-1 var-2 … &allow-other-keys)`. The source is
closed before this function returns; the returned function is
self-contained. Each free template variable is one keyword
parameter; missing keys signal `elp-template-error` with line/column
information. Extra keyword arguments pass through
`&allow-other-keys` and are dropped.

**`(filepath-source pathname)` → source**

Convenience dispatcher: returns an `mmap-source` for a regular
file, or a `string-source` of `""` for an empty file (since
`mmap(2)` rejects size 0). Use this when you have a pathname and
don't want to think about the empty-file edge case.

**`(mmap-source pathname)` → mmap-source**

Bare backend constructor. `pathname` must point to a regular file
of size > 0. Use directly when you've already established that
invariant; otherwise prefer `filepath-source`.

**`(string-source text &key (name "<string>"))` → string-source**

Wraps a Lisp string. `name` (default `"<string>"`) is the display
name used in error messages.

**`(close-source source)`**

Releases any OS resources the source holds. Idempotent; no-op on
`string-source`. Most callers don't invoke this directly —
`render` / `compile-template` / `translate-template` do it
automatically.

**Two layers: `open-template` and `closed-template`**

Translation runs in two composed steps. `open-template` carries the
template body wrapped in just enough scaffolding to be evaluable
(the source-specific lexical context plus the runtime-error
handler-bind) — free variables stay as bare symbols, no keyword-arg
signature shadowing them. `closed-template` wraps an open-template
with the callable `(lambda (stream &key …))` signature and
supplied-p discipline; it's what `compile-template` compiles.

Both implement a shared `template` protocol:

- **`(template-text t)`** — string. PRIN1'd generated code, READable.
- **`(template-form t)`** — convenience: `(read-from-string (template-text t))`.
- **`(doc-offset->source-byte t doc-offset)`** / **`(source-byte->doc-offset t source-byte)`**
  — paired position mapping. Forward direction returns the
  originating source byte (NIL for synthesized wrapper / delimiter /
  text-emit territory). Reverse returns the document offset where
  `source-byte` appears (NIL if the byte doesn't surface in the
  document, e.g. inside a stripped `<%# comment %>`). Both default
  to identity via T methods, so byte-equivalent translators get
  no-op behavior for free.

**`(translate-template source)` → `closed-template`**

Returns the callable lambda surface. `compile-template` is literally
`(compile nil (read-from-string (closed-template-text
(translate-template source))))` — the closed-template is the
canonical surface; the compiled function is one `read-from-string` +
`compile` away.

**`(translate-open source)` → `open-template`**

Returns the bare emitter surface — same source, one fewer wrap.
Useful for Lisp LSPs / static analyzers that want template-body
references (`<%= name %>`) to resolve to whatever lexical scope the
host project provides, instead of being shadowed by a synthesized
`&key` parameter.

```lisp
(let ((tt (translate-template (filepath-source #p"foo.elp"))))
  (template-text tt)               ; → "(lambda (stream &key name) …)"
  (closed-template-open tt)        ; → #<open-template …>
  (doc-offset->source-byte tt 42)  ; → 17 (or NIL)
  (source-byte->doc-offset tt 17)) ; → 42 (or NIL)

(let ((st (translate-open (filepath-source #p"foo.elp"))))
  (template-text st)               ; → "(let ((elp::source …)) (handler-bind …))"
  (open-template-free-vars st))    ; → (NAME)
```

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

### One stream, two materialized layers

A `template-body-stream` is a Gray input stream wrapped around a
source (mmap-source or string-source). It synthesizes a continuous
character stream of Lisp: literal text spans become
`(elp::write-mmap-range elp::ptr START END)` calls (for mmap-source —
zero-copy at render time) or `(write-string "literal")` calls (for
string-source — inlined); `<%= … %>` blocks become
`(let ((elp::*current-template-span* '(S E))) (format t "~A" body))`;
`<% … %>` blocks pass the body chars through unchanged. Position-map
checkpoints accumulate at chunk transitions, mapping
character-positions to source bytes.

The drain feeds two composed layers:

- **`open-template`** wraps the inner chars in
  `source-wrap-lambda-body` (binds `elp::source`, plus
  `elp::ptr/size/fd` for mmap-source) and a `handler-bind` that
  translates runtime errors inside the body into
  `elp-template-error` with source line/column from
  `*current-template-span*`. Its text, when READ and evaluated,
  emits to current `*standard-output*` given free-var bindings.
- **`closed-template`** wraps an open-template in
  `(lambda (stream &key …) (let ((*standard-output* stream)) …))`
  with one supplied-p check per free variable and an outer
  `handler-bind` that translates missing-kwarg `unbound-variable`
  errors into `elp-template-error`. `compile-template` is then a
  one-line `read-from-string` + `compile` over `template-text`.

Each layer pre-shifts its inner position-map by the prefix length
its outer text adds, so position-map keys always index directly
into that layer's text. The two `handler-bind`s split cleanly by
responsibility: open-template's catches body-runtime errors (needs
`elp::source` in scope); closed-template's catches supplied-p
unbound-variables (no template span; line/col=1/1).

### Source protocol

Anything that can act as a byte source for the template engine
implements a small generic-function protocol: `source-length`,
`source-byte`, `source-search` (memmem-shape), `source-substring`,
`source-line+column`, `source-name`, `source-emit-text-form` (render
codegen for literal text), `source-wrap-lambda-body` (per-source
outer wrap). Two concrete classes today (`mmap-source`,
`string-source`); the inner state machine is backend-agnostic.

### Vectorized scanning, zero-copy render

For mmap-source, literal text spans are located via libc `memmem`
on the mapped region — only the bytes inside `<% ... %>` blocks pass
through the Lisp reader. The file is never slurped into a Lisp
string. At render time, `write-mmap-range` writes those bytes to an
`sb-sys:fd-stream` via a single `write(2)` syscall directly on the
mapped pages — zero copy through Lisp.

For string-source, `cl:search` replaces `memmem` (the scanning
protocol is generic) and literal text becomes inlined `write-string`
calls in the compiled lambda — no runtime source binding needed.

### Multi-block constructs

`<% (dolist ... %> body <% ) %>` works because the standard reader is
in the middle of building a list when the body-stream transitions
through `%> ... text ... <%`. The synthesized text-emit forms get
appended to the in-progress list naturally — there's no special
multi-tag handling.

### Position tracking + error translation

The body-stream records `(reader-position . source-byte)`
checkpoints whenever its emission transitions between
source-anchored and synthesized regions. Reader errors translate to
`elp-template-error` with `file:line:column` by looking up the
reader's stop position in the position-map, falling back to
`source-line+column` for the line/col conversion (libc `memchr` for
mmap-source — vectorized newline scan).

Both `open-template` and `closed-template` inherit the position-map
for their body region (with keys shifted by each layer's prefix
length); prefix/suffix chars (synthesized wrapper) return NIL from
`doc-offset->source-byte`. That's how an LSP turns a cursor in its
translated buffer back into a source-file byte.

