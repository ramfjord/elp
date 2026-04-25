# String input for `render`

## Goal

`render` accepts in-memory strings and character streams in addition to
file pathnames. The mmap-backed file path stays the fast path; non-file
sources get a slurp-then-render backend that uses `write-string`
instead of zero-copy `write(2)`.

By the end of this plan:

- `(elp:render-string template-string context &key name)` works.
- `(elp:render-stream stream context &key name)` works (slurp +
  delegate).
- The CLI accepts `-` (or no positional) and reads from stdin, naming
  the source `"<stdin>"` in any `elp-template-error`.
- `elp:render-form` exposes the generated sexp without evaluating it,
  for codegen debugging and for testing the file-vs-string backends
  emit the right code.

Polymorphic `(elp:render input)` dispatch and a few naming/UTF-8
cleanups are deferred to follow-up plans (see *Future plans*).

## Context

Today `tokenize-file` already slurps the entire file into a Lisp string
and tokenizes that — so tokenization is *not* zero-copy. The mmap win
exists only at render time: literal template text is written from the
mmap'd pages straight to stdout via `write(2)` without touching the
Lisp string heap. That means generalizing source acquisition is mostly
a code-generation question, not an architecture question: swap one
emit form for another and most of the engine is unchanged.

Motivating use case: piping into the CLI (`cat foo.elp | elp -`),
which is currently impossible because `render` insists on a pathname.

## Related plans

- **`swank-elp-source-locations.md`** — overlaps on codegen. Its
  Layer 2 wants to replace `read-from-string` with `compile-file` so
  SBCL backtraces report `.elp` files. Its Layer 4 explicitly flags
  this plan: *"if Layer 2 moves to compile-file, the string-rendering
  TODO becomes 'compile-string with a synthetic pathname' and the two
  designs should be reconciled rather than diverging."*

  Sequencing: this plan ships first. The emit-fn refactor below is a
  strict generalization that the swank plan can build on — once
  codegen is parameterized, swapping `read-from-string` for
  `compile-file` happens in the same factored seam without re-touching
  the file-vs-string split. If we did them in the opposite order
  we'd have to re-do the codegen factoring.

  Action for the swank plan: when its Layer 2 lands, the string
  backend's wrapper should switch from a `let`-binding into a
  `compile-string`-with-synthetic-pathname call.

- `TODOs.md` line "String-based rendering" is the seed of this plan
  and should be removed when this plan ships.

## Design notes

These apply across multiple commits below; written once here so each
commit's description can stay short.

### Emit-fn shape

`generate-render-code` currently bakes
`(elp::write-output-range elp::ptr S E)` into the emitted body for
`:text` tokens, and the body is wrapped in a
`(multiple-value-bind (ptr size fd) (%mmap-open …) …)`. Both pieces
are file-specific.

Refactor so `generate-render-code` takes an **emit-fn** of signature
`(start end) → form`, called for each `:text` token. It returns the
body sexp (a `progn`) plus checkpoints; the **caller** wraps the body
with whatever bindings the emit-fn references.

- File caller: emit-fn = `(lambda (s e) `(write-output-range ptr ,s ,e))`,
  wrapper = the existing `multiple-value-bind` around `%mmap-open`.
- String caller: emit-fn = `(lambda (s e) `(write-string input nil
  :start ,s :end ,e))`, wrapper = `` `(let ((input ,source-string))
  ,body) ``.

### Why `let`-wrap, not a special variable

For binding `input` into the generated form, considered a special
variable (`*template-source*`). Lexical `let`-wrap wins:

- No global state — string lives only for the eval's extent.
- No leakage — template expressions can call user code; a special
  would be visible to all of it.
- Symmetry with the file path's `multiple-value-bind`.

The string is spliced **as an object** via backquote *after*
`read-from-string` parses the body — no escaping, no re-reading, no
codegen bloat.

We keep `*current-template-span*` as a special, because that one
genuinely needs to cross dynamic scope (handler in `render`'s frame,
binding pushed deep inside the eval).

### Eval/lexical-scope footnote

The form is `eval`'d in the null lexical environment, so emit-fns
cannot lexically close over caller-side variables. Free variables in
emitted forms must be bound either by a generated wrapper (this plan)
or by a special variable in dynamic scope.

### Slurp, don't true-stream

For `render-stream`: read the whole input into a string, then call
`render-string`. Tokenization needs random access into the source for
byte ranges, and templates are almost always small. If anyone hits a
real need for unbounded streaming later, add it then.

## Commits

Ordered. Each leaves the tree green (`make test` passes) and is a
single reviewable diff.

1. **Generalize `byte->line+column` to take a source string + display
   name.** Pure refactor. Today it re-opens the pathname; new
   signature is `(byte->line+column-in source-string byte-offset)`.
   `render` slurps the file once for error reporting purposes (cheap
   — the file is already mmap'd) and passes the string through.
   `elp-template-error-file` keeps its name; its value is now a
   display name (pathname or string), defaulting to the pathname for
   the file backend so existing tests pass unchanged.
   *Verify:* existing error-reporting tests still pass.

2. **Refactor `generate-render-code` to take an emit-fn + caller-owned
   wrapper.** Pure refactor; only the file backend exists. Caller
   (`render`) provides the file emit-fn and the `multiple-value-bind`
   wrapper. Body shape, checkpoints, error machinery unchanged.
   *Verify:* `make test` (40/40) still passes; rendered output of
   existing fixtures byte-identical.

3. **Add `render-form` for the file backend.** New exported function
   that returns the sexp `render` would eval, without evaluating it.
   Useful for REPL inspection (`(pprint (elp:render-form #P"foo.elp"
   '()))`). Includes the mmap wrapper — contract is "what would be
   eval'd."
   *Verify:* test that `render-form` returns a `multiple-value-bind`
   form whose body contains `write-output-range`.

4. **Add `render-string` (and string-backend `render-form`).**
   New exported `(render-string template-string context &key (name
   "<string>"))`. Uses the string emit-fn and `let`-wrap from the
   design notes. `render-form` learns to dispatch on input type
   (string → string codegen). The display name flows into
   `elp-template-error-file` for any failures.
   *Verify:* mirror the existing render tests against `render-string`
   (text, expressions, code blocks, comments). Add a test that
   triggers an error and asserts the supplied `:name` appears in the
   condition. Add a codegen-diff test using `render-form`: file
   backend emits `write-output-range`; string backend emits
   `write-string`.

5. **Add `render-stream` and CLI stdin support.** New exported
   `(render-stream stream context &key (name "<stream>"))` —
   slurps to string, delegates to `render-string`. CLI: detect `-`
   positional or no positional → read all of `*standard-input*` and
   call `render-stream` with `:name "<stdin>"`.
   *Verify:* unit test for `render-stream` with a string-input-stream.
   CLI smoke test: `echo "hi <%= 1 %>" | ./bin/elp -` → `"hi 1"`.

## Future plans

When this plan ships, draft these (each its own branch):

- **Polymorphic `render` dispatch.** Make `render` dispatch on input
  type: pathname → file path, stream → stream path, string → string
  path. Be deliberate about the string-vs-pathname-string footgun —
  string is *always* template content; callers wanting "path as
  string" use `render-file` or wrap with `(pathname …)`. Probably
  alias `render-file` ← current file implementation as part of this
  plan so the convention is stable from day one.

- **Naming + UTF-8 audit.** Rename `elp-template-error-file` slot
  →`source` (with deprecated reader alias). Audit byte-vs-char offset
  claims: README says "byte offsets" but the tokenizer produces char
  offsets. ASCII-clean today; multibyte-broken on the mmap path.
  Either fix the mmap path to do real UTF-8 byte indexing, or
  document the ASCII assumption and rename.

## Non-goals

- True streaming tokenization (no slurp).
- Network/socket-specific code. `render-stream` takes any character
  stream; the caller opens it.
- Reconciling with `swank-elp-source-locations.md`'s Layer 2 in this
  plan — done as part of that plan when its Layer 2 lands. This
  plan's job is to leave the seam in the right shape.
