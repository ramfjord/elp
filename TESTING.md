# ELP Testing Guide

This project uses **FiveAM** — the most popular testing framework in Common Lisp, inspired by RSpec.

## Installation

FiveAM is available via Quicklisp (Common Lisp's package manager):

```lisp
(ql:quickload :fiveam)
```

If you don't have Quicklisp installed:

```bash
# Install Quicklisp
curl -O https://beta.quicklisp.org/quicklisp.lisp
sbcl --load quicklisp.lisp --eval '(quicklisp-quickstart:install)' --quit

# Add to ~/.sbclrc to auto-load on startup:
# (load "~/quicklisp/setup.lisp")
```

## Running Tests

### From Command Line (recommended)

```bash
sbcl --load ~/quicklisp/setup.lisp \
     --eval "(push #p\"/path/to/elp/\" asdf:*central-registry*)" \
     --eval "(asdf:load-system :elp/tests)" \
     --eval "(elp-test:run-tests)" \
     --eval "(quit)"
```

### Interactive REPL

```bash
sbcl --load ~/quicklisp/setup.lisp
CL-USER> (push #p"/path/to/elp/" asdf:*central-registry*)
CL-USER> (asdf:load-system :elp/tests)
CL-USER> (elp-test:run-tests)
```

## Test Organization

Tests are in `elp-test.lisp` and organized into the `generate-suite`:

- **Basic Rendering** — Text output, single/multiple expressions
- **Variable Binding** — Context variable binding and reference
- **Code Blocks** — Code execution without output
- **Comments** — Comment tokenization and removal
- **Complex Expressions** — String ops, list output, formatting
- **Edge Cases** — Empty expressions, consecutive delimiters
- **Whitespace** — Newline and space preservation

## Test Design

Tests use an RSpec-style integrated macro `expect-render` that validates:

1. **Tokenization** — Template parses to expected token structure
2. **Rendering** — Final output matches expected result

```lisp
(test my-test
  "Description of what this tests"
  (expect-render "template <%= expr %>"
    '((:text "template ") (:expr "expr"))
    "template result"
    nil))  ; optional context alist
```

### With Context Variables

```lisp
(test variable-binding
  "Test variables from context"
  (expect-render "Name: <%= name %>"
    '((:text "Name: ") (:expr "name"))
    "Name: Alice"
    '((name . "Alice"))))
```

## Test Syntax

FiveAM syntax:

```lisp
(test test-name
  "Description of what this tests"
  (is (equal (actual-result) (expected-result))))

(test test-with-error
  "Test that something signals an error"
  (signals error
    (code-that-should-error)))

(test multiple-assertions
  "Can have multiple assertions"
  (is (equal x y))
  (is (> a b))
  (is (member x (list a b c))))
```

## Assertion Types

Common assertions in FiveAM:

```lisp
(is (equal x y))           ; Equality
(is (= a b))               ; Numeric equality
(is (string= s1 s2))       ; String equality
(is (member x list))       ; List membership
(is condition)             ; Boolean truth
(is-true condition)        ; Explicit boolean
(is-false condition)       ; Explicit false
(signals error-type expr)  ; Catches errors
(finishes expr)            ; Code doesn't hang
(skip "reason")            ; Skip this test
```

## Test Coverage

Areas tested:

- Plain text and expressions
- Multiple expressions in one template
- Code blocks and comments
- String concatenation, lists, numbers
- Context variable binding
- Whitespace preservation (spaces, newlines)
- Edge cases (empty expressions, consecutive delimiters)

### Known Limitations (not yet tested)

- Multi-token code blocks (loops/lets spanning delimiters)

## Debugging Failed Tests

When a test fails, FiveAM shows:

- Test name and description
- Assertion that failed
- Expected vs actual values

To investigate interactively:

```lisp
CL-USER> (elp-test:run-tests)
; If test fails, investigate:
CL-USER> (elp:render #p"test.elp" '((x . 5)))
```

## Adding New Tests

1. Open `elp-test.lisp`
2. Add a new `(test ...)` form before the final test runner
3. Use the `expect-render` macro to define your test
4. Run tests and verify they pass

Example:

```lisp
(test my-new-feature
  "Test a new feature"
  (expect-render "Hello <%= greeting %>"
    '((:text "Hello ") (:expr "greeting"))
    "Hello World"
    '((greeting . "World"))))
```

## References

- [FiveAM documentation](https://common-lisp.net/project/fiveam/)
- [Common Lisp Testing libraries](https://www.quicklisp.org/beta/#testing)
- [ASDF Manual](https://asdf.common-lisp.dev/)
