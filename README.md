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
silently formats only `+` and discards `1 2`.

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

**`(render pathname context-alist &optional stream)`**

Renders a template, streaming output bytes directly to `stream`
(defaults to `*standard-output*`). Output is produced as bytes are
generated, with no intermediate Lisp string. When `stream` is an
`sb-sys:fd-stream` (e.g. the CLI's `*standard-output*` in a saved
binary), literal text ranges are written via a single `write(2)`
syscall directly on the mmap'd source — zero copy through Lisp.

- `pathname`: A file path (pathname object)
- `context-alist`: List of `(symbol . value)` pairs
- `stream`: Destination stream (default: `*standard-output*`)
- Returns: no useful value; consumers care about side effects on `stream`

For callers that want the output as a string, wrap in
`with-output-to-string`:

```lisp
(with-output-to-string (s)
  (render #p"template.elp" '((name . "Alice")) s))
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

## Known Limitations

See [TODOs.md](TODOs.md).

## Future Enhancements

- Caching of parsed templates and generated code
- Whitespace trimming modes (`%-`, `-%`)
- Custom delimiter sets
