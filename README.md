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

**`(render pathname context-alist) → string`**

Renders a template file with the given context variables.

- `pathname`: A file path (pathname object)
- `context-alist`: List of `(symbol . value)` pairs
- Returns: Rendered output as a string

### Advanced API

**`(tokenize-file pathname) → token-list`**

For advanced use cases, tokenize a template file and inspect/manipulate tokens directly.

Each token is a list: `(type content start-byte end-byte content-start-byte content-end-byte)`

- `type`: `:text`, `:expr`, `:code`, or `:comment`
- `content`: The token content as a string
- `start-byte`, `end-byte`: Byte offsets of the full token (including `<% %>` delimiters) in the file
- `content-start-byte`, `content-end-byte`: Byte offsets of the token's inner content (between the delimiters); used for error reporting

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

- Templates are parsed into tokens (text, code, expressions, comments)
- Code generation creates an executable S-expression
- Variables are bound in a `let` form within the generated code
- Text sections are output by `write-output-range` which reads directly from the template file
- Expressions are formatted to strings with `format nil "~A"`

## Known Limitations

See [TODOs.md](TODOs.md).

## Future Enhancements

- Error handling with line numbers for template syntax errors
- Caching of parsed templates and generated code
- Whitespace trimming modes (`%-`, `-%`)
- Custom delimiter sets
- Multi-token code block support (loops/lets spanning delimiters)
