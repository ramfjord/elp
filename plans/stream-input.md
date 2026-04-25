# String / stream input for `render`

## Goal

`render` accepts not just file pathnames, but also in-memory strings and
arbitrary character streams (stdin, sockets, pipes). The mmap-backed
file path stays the fast path; non-file sources get a slurp-then-render
backend that uses `write-string` instead of zero-copy `write(2)`.

By the end of the three passes:

- `(elp:render-string template-string context &key name)` works.
- `(elp:render-stream stream context &key name)` works (slurp + delegate).
- `(elp:render input context)` is polymorphic — pathname / string / stream.
- The CLI accepts `-` (or no positional) and reads from stdin, naming
  the source `"<stdin>"` in any `elp-template-error`.
- `elp:render-form` exposes the generated sexp without evaluating it,
  for codegen debugging and for testing the file-vs-string backends
  emit the right code.

## Context

Today `tokenize-file` already slurps the entire file into a Lisp string
and tokenizes that — so tokenization is *not* zero-copy. The mmap win
exists only at render time: literal template text is written from the
mmap'd pages straight to stdout via `write(2)` without touching the
Lisp string heap. That means generalizing source acquisition is
mostly a code-generation question, not an architecture question:
swap one emit form for another and most of the engine is unchanged.

Motivating use case: piping into the CLI (`cat foo.elp | elp -`),
which is currently impossible because `render` insists on a pathname.

## Related plans

- **`swank-elp-source-locations.md`** — overlaps directly on codegen.
  Its Layer 2 wants to replace `read-from-string` with `compile-file`
  so SBCL backtraces report `.elp` files. Its Layer 4 explicitly
  flags this plan: *"if Layer 2 moves to compile-file, the string-
  rendering TODO becomes 'compile-string with a synthetic pathname'
  and the two designs should be reconciled rather than diverging."*

  Sequencing call: this plan ships first. The emit-fn refactor in
  Pass 1 is a strict generalization that the swank plan can build on
  — once codegen is parameterized, swapping `read-from-string` for
  `compile-file` happens in the same factored seam without re-touching
  the file vs. string split. If we did them in the opposite order
  we'd have to re-do the codegen factoring.

  Action for the swank plan: when its Layer 2 lands, the string
  backend's "wrap" should switch from a `let`-binding into a
  `compile-string`-with-synthetic-pathname call. Note this in the
  swank plan's Layer 4 once Pass 1 lands here.

- `TODOs.md` line "String-based rendering" is the seed of this plan
  and should be removed when Pass 1 ships.

## Approach

Three passes, each ending in a green test run. Pass 1 is the
substantive refactor; passes 2 and 3 are polish.

### Pass 1 — string source as a peer of file source

#### Codegen refactor: emit-fn parameter

`generate-render-code` currently bakes `(elp::write-output-range
elp::ptr S E)` into the emitted body for `:text` tokens, and wraps
the body in a `(multiple-value-bind (ptr size fd) (%mmap-open …) …)`.
Both pieces are file-specific.

Refactor so `generate-render-code` takes an **emit-fn** of signature
`(start end) → form`, called for each `:text` token. It returns the
body sexp (a `progn`) plus checkpoints; the **caller** wraps the
body with whatever bindings the emit-fn references.

- File caller: emit-fn = `(lambda (s e) `(write-output-range ptr ,s ,e))`,
  wrapper = the existing `multiple-value-bind` around `%mmap-open`.
- String caller: emit-fn = `(lambda (s e) `(write-string input nil
  :start ,s :end ,e))`, wrapper = `` `(let ((input ,source-string))
  ,body) ``. The string is spliced **as an object** via backquote
  *after* `read-from-string` parses the body — no escaping, no
  re-reading, no codegen bloat. The `let` binds it lexically for
  the duration of the eval; it's GC-able afterward.

##### Why `let`-wrap and not a special variable

We considered binding `*template-source*` as a special and reading
it from the emitted `write-string` calls. Both work; lexical wins
on three counts:

- No global state — the string lives only for the eval's extent.
- No leakage — template expressions can call user code, and a
  special would be visible to all of it. A lexical `input` binding
  isn't reachable outside the generated form.
- Symmetry with the file path, which already uses
  `multiple-value-bind` to introduce `ptr`/`size`/`fd` lexically.

The one special variable we keep is `*current-template-span*`,
because it genuinely needs to cross dynamic scope (the
`handler-bind` lives in `render`'s frame; the binding is pushed
deep inside the eval'd form). Right tool for that job.

##### Eval/lexical-scope footnote

Since the form is `eval`'d in the null lexical environment, an
emit-fn cannot lexically close over caller-side variables. Free
variables in emitted forms must be resolved at eval time — bound
either by a generated wrapper (this plan) or by a special variable
in dynamic scope. This is why the wrapper is the caller's
responsibility, paired with whatever free variables its emit-fn
references.

#### Error reporting generalization

`byte->line+column` currently re-opens the pathname and counts
characters. For string sources there is no pathname. Generalize to
take a source *string* + a *display name*:

```
(byte->line+column-in source-string byte-offset) → (values line col)
```

`render` reads the file once for error reporting; `render-string`
passes its input directly. The `elp-template-error-file` reader
keeps its current name in Pass 1 (rename deferred to Pass 3) but
its value is the display name — `"<stdin>"`, `"<string>"`, an
explicit caller-supplied name, or a pathname.

#### New public functions

- `render-string template-string context &key (name "<string>")`
- `render-stream stream context &key (name "<stream>")` — slurps to
  string, delegates to `render-string`. (Slurp, don't true-stream:
  tokenization needs random access into the source for byte ranges,
  and templates are almost always small. If anyone hits a real need
  for unbounded streaming later, add it then.)
- `render-form input context &key name` — returns the sexp `render`
  *would* eval, without evaluating. Dispatches the same way the
  user-facing renderer does (file → mmap codegen, string → string
  codegen). Useful for `(pprint (elp:render-form …))` at the REPL
  and for codegen tests that assert the right emit form is used per
  backend without running anything.

Export all four (`render-string`, `render-stream`, `render-form`,
plus the existing `render`).

#### CLI

Detect `-` as a positional, or no positional, → read all of
`*standard-input*` and call `render-stream` with `:name "<stdin>"`.
The library never auto-detects; the CLI is the one that knows
what its source is and names it.

#### Tests

- Mirror the existing render tests against `render-string` (golden
  rendering, expressions, code blocks, comments). The cleanest way
  is to factor each existing test's body to take a render function
  and run it against both backends.
- Stdin-named error test: trigger an `elp-template-error` from a
  string source and assert the source name (`"<stdin>"`) appears
  in the condition.
- Codegen test: `(elp:render-form …)` for the same logical template
  via file backend and string backend; assert the file form contains
  `write-output-range` and the string form contains `write-string`.

### Pass 2 — polymorphic `render`

`render` dispatches on input type:

- `pathname` → file path (mmap fast path).
- `stream` → stream path (slurp + render-string).
- `string` → string path.

The string-vs-pathname-string ambiguity is the classic footgun. Be
deliberate: `string` is *always* template content. Callers who want
"path expressed as a string" must wrap with `(pathname …)` or call
`render-file` explicitly. (Probably alias `render-file` ← current
file-path implementation in Pass 1 so this convention is stable from
day one.)

`render-string` / `render-stream` stay as the unambiguous primitives;
`render` is sugar over them.

### Pass 3 — naming + UTF-8 honesty

- Rename the condition slot `file` → `source` with a deprecated
  reader alias `elp-template-error-file` for one release.
- Audit byte-vs-char offsets. The README says "byte offsets" but the
  tokenizer produces *char* offsets (it operates on a Lisp string).
  For ASCII it's a wash. For multibyte UTF-8 the mmap path is
  currently wrong: `write-output-range` does byte indexing into the
  mmap'd file but receives char indices from the tokenizer. The
  string path is incidentally *more* correct. Either:
  - Fix mmap to do real byte indexing during tokenization (decode
    UTF-8 while scanning, emit byte offsets), or
  - Document the ASCII assumption and rename "byte" → "char" in
    docs and field names.

  Pick one based on whether anyone is actually using multibyte
  templates yet. If not, the doc fix is enough.

## Open questions

- Should `render-stream` accept `:eof-error t` semantics, or always
  read-to-eof? Probably always read-to-eof; the slurp is the whole
  point.
- For `render-form`, what does it return for the file backend — the
  form including the `multiple-value-bind` mmap wrapper, or the
  unwrapped body? Probably the wrapped form, since "what would be
  eval'd" is the contract; offer the body as a secondary value if
  it turns out to be useful.

## Non-goals

- True streaming tokenization (no slurp). Templates are small;
  defer until someone has a real complaint.
- Network/socket-specific code. `render-stream` takes any character
  stream; the caller opens it.
- Reconciling with `swank-elp-source-locations.md`'s Layer 2 in this
  plan — done as part of that plan when its Layer 2 lands. This
  plan's job is to leave the seam in the right shape.
