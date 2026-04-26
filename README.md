# ELP - Embedded LisP

A template system for Common Lisp that allows embedding Lisp code and expressions in text files, similar to ERB (Embedded Ruby).

## Syntax

- `<%= lisp-expression %>` — Evaluates the expression and outputs the result
- `<% lisp-code %>` — Executes Lisp code without producing output
- `<%# comment %>` — Comments (removed from output)

## Usage

### Basic Example - Render from File

```lisp
(use-package :elp)

(render #p"template.elp"
  '((name . "Alice")
    (age . 30)))
;; Output: "Hello Alice, you are 30 years old."
```

Where `template.elp` contains:
```erb
Hello <%= name %>, you are <%= age %> years old.
```

### With Conditionals

`template.elp`:
```erb
Name: <%= name %><% when (> age 30) %> (senior)<% ) %>
```

```lisp
(render #p"template.elp"
  '((name . "Bob")
    (age . 35)))
;; Output: "Name: Bob (senior)"
```

### Using with Full Lisp Power

Since the template has access to full Common Lisp, you can use any Lisp functions:

```erb
[Unit]
Description=<%= desc %> (<%= name %>)
<% dolist (path config-files) %>
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
<% when enabled %>
Active
<% ) %>
```

## API

### Public API

**`(render-to-stream pathname context-alist &optional stream)`**

Streams a rendered template directly to `stream` (defaults to
`*standard-output*`). This is the engine's primitive — output bytes are
written as they are produced, with no intermediate Lisp string. When
`stream` is an `sb-sys:fd-stream` (e.g. the CLI's `*standard-output*`
in a saved binary), literal text ranges are written via a single
`write(2)` syscall directly on the mmap'd source — zero copy through
Lisp.

- `pathname`: A file path (pathname object)
- `context-alist`: List of `(symbol . value)` pairs
- `stream`: Destination stream (default: `*standard-output*`)
- Returns: no useful value; consumers care about side effects on `stream`

**`(render pathname context-alist) → string`**

Thin wrapper around `render-to-stream` for callers that want the output
as a string. Equivalent to
`(with-output-to-string (s) (render-to-stream pathname context-alist s))`.

- `pathname`: A file path (pathname object)
- `context-alist`: List of `(symbol . value)` pairs
- Returns: Rendered output as a string

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

- The template file is `mmap`'d once. Tokenization scans the mapped bytes
  directly via libc `memmem`, so the file is never slurped into a Lisp
  string and the tokenizer cost scales with delimiter count rather than
  template size.
- Tokens carry byte offsets into the mapping. Literal text ranges are
  written by `write-output-range`, which reads straight from the mmap.
  When the destination is an `sb-sys:fd-stream` (e.g. the CLI's stdout
  in a saved binary), this is a single `write(2)` syscall on the mapped
  pages — zero copy through Lisp.
- Embedded code (`<% %>`) and expressions (`<%= %>`) are spliced into a
  single `(progn …)` body, read once via `read-from-string`, and
  evaluated against the live mmap. Multi-token constructs like loops
  work naturally because the body is one form, not many.
- Error byte offsets are translated to (line, column) by counting
  newlines in the mapping with libc `memchr`, so the prefix scan is
  vectorized rather than per-byte.

## Known Limitations

See [TODOs.md](TODOs.md).

## Future Enhancements

- Error handling with line numbers for template syntax errors
- Caching of parsed templates and generated code
- Whitespace trimming modes (`%-`, `-%`)
- Custom delimiter sets
- Multi-token code block support (loops/lets spanning delimiters)
