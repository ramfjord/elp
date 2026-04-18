# ELP

An ERB-style template engine for Common Lisp (SBCL).

## Building & testing

- `make bin/elp` — build the CLI binary
- `make test` — run the FiveAM test suite (requires Quicklisp with `fiveam`)

See `README.md` for usage and token structure, and `TESTING.md` for test
organization, conventions, and how to add new tests.

## Layout

- `elp.lisp` — tokenizer and renderer
- `cli.lisp` — CLI entry point
- `elp-test.lisp` — FiveAM tests
- `elp.asd` — ASDF system definition
