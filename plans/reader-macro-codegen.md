# Reader-driven codegen (no source-string assembly)

Branch: reader-macro-codegen
Plan source: ./plans/reader-macro-codegen.md

## Goal

Replace the current "tokenize → assemble Lisp source as a string →
`read-from-string`" pipeline with a single pass where the **standard
Lisp reader** walks the template directly and produces the body sexp
structurally. The mmap + `memmem` / `memchr` scanning that the file
path already uses for delimiter and newline discovery stays in place
— it just moves under the reader instead of being a separate
tokenizer phase.

By the end of this plan:

- `tokenize-mmap` and `generate-render-code`'s string-assembly +
  `read-from-string` path are gone. In their place is one function
  that returns the body sexp by reading the template through a
  custom **gray stream** wrapped around the mmap.
- The gray stream is the variation point: it synthesizes Lisp
  source characters on the fly (`(write-output-range ...)` for
  text spans, `(let ((*current-template-span* ...)) (format t "~A"
  ` ... ` ))` around expression blocks), so the standard reader
  consumes one continuous stream and returns one sexp without ever
  seeing template syntax.
- Text spans are still located via `memmem` (no per-byte Lisp loop
  over template text); comment spans still skip via `memmem`;
  error-reporting line counts still go through `memchr`. The
  vectorized scanning that `mmap-tokenize.md` introduced is
  preserved end-to-end — the reader only consumes characters from
  *inside* code/expr blocks (small, bounded by embedded-code size)
  and from synthesized prefix/suffix chunks (also tiny).
- Multi-block constructs (`<% (dolist (x xs) %> body <% ) %>`) keep
  working, because the standard reader's `(` reader macro is in the
  middle of building the `dolist` form when the gray stream
  transitions through `%>`...text...`<%` — the synthesized text-emit
  forms get appended to the in-progress list naturally.
- `translate-read-error`'s checkpoint machinery shrinks dramatically:
  the gray stream tracks a live mapping from "characters fed to the
  reader" → "byte offset in the mmap," so reader errors carry an
  exact file byte without the body-string-offset detour.
- Generated forms get **per-form source locations** for free, via
  the same byte-offset tracking — the bridge that
  `swank-elp-source-locations.md` Layer 2 wants to build is mostly
  this plan's stream class.

Zero-copy on the output side is unchanged: the synthesized
`write-output-range` calls reference `elp::*template-ptr*` and run
through the same `write(2)` path that exists today.

## Context

Today's flow is "two parsers stacked": `tokenize-mmap` walks the
file with `memmem` and emits `(type content start end ...)` tuples,
then `generate-render-code` walks the tuples and writes a Lisp
**source string** to a `string-output-stream`, then
`read-from-string` parses that string into the body sexp. The
string assembly is the awkward middle step:

- It allocates a Lisp string proportional to the **embedded-code
  total length plus the synthesized wrapper boilerplate** for every
  text/expr token (`generate-render-code` writes
  `"(elp::write-output-range elp::*template-ptr* S E) "` per text
  token — small per-call but linear in token count). For a
  text-heavy template that's a real number, even though the *text
  bytes themselves* never enter the heap.
- It needs a checkpoints list to map reader-error positions in the
  body string back to file byte offsets, plus a
  `translate-read-error` function that reconstructs the mapping.
  Pure mechanism, no semantic value — it exists only because we
  parsed an intermediate string.
- It blocks per-form source locations
  (`swank-elp-source-locations.md` Layer 2): the reader sees
  positions inside the synthesized body string, not inside the
  `.elp` file. Wiring source-locations through that requires
  rebuilding the byte-offset bridge form by form.

The reader-driven version collapses tokenize + codegen into one
pass against one stream. The gray stream is the place where mmap
scanning, character synthesis, and position tracking all live —
the rest of the engine (codegen as a sexp transformer, render
flow, error reporting) gets simpler, not more complex.

This is also the cleanest place to land per-form source locations:
the stream knows, for every character it hands to the reader,
which `.elp` byte that character came from (or, for synthesized
chars, which `.elp` byte the surrounding construct came from). A
"read one form, ask the stream where it started" loop gives swank
Layer 2 with no extra checkpoint mechanism.

## Related plans

- **`stream-input.md`** — drafted, not in flight. Adds
  `render-string` / `render-stream` and CLI stdin. **Sequencing:
  this plan lands first.** Reasons:

  - That plan's commit 2 introduces an **emit-fn** parameter on
    `generate-render-code` so the file backend emits
    `write-output-range` and the string backend emits
    `write-string`. After this plan, `generate-render-code` is gone
    — the variation point becomes the **gray stream class**, not an
    emit-fn. The string backend implements its own gray-stream
    subclass that synthesizes `write-string` chars and uses
    `cl:search` (no mmap) for delimiter location. Doing emit-fn
    first means rewriting it on top of this; doing this first
    means stream-input's commit 2 turns into "add a
    string-backed gray stream class," which is the right shape
    anyway.

  - That plan's commit 1 (`byte->line+column-in source-string …`)
    is a generalization this plan doesn't conflict with — both
    backends still need line/column lookup. Land it as part of
    stream-input as drafted, just on top of this plan instead of
    underneath.

  - That plan's commit 3 (`render-form` for codegen inspection)
    survives unchanged in spirit — it just returns a sexp produced
    by reading through the gray stream rather than by string
    assembly.

  Action: when this plan ships, redraft `stream-input.md` so its
  commit 2 becomes "add a string-backed gray-stream class" and
  drop the emit-fn vocabulary.

- **`swank-elp-source-locations.md`** — drafted, not in flight.
  **This plan supersedes its Layer 2.** Layer 2 proposes a
  "custom read-with-locations" loop that reads forms one at a
  time, captures `file-position` before each read, and translates
  via the existing checkpoints. That is essentially this plan,
  done worse: it would build the bridge through the assembled
  body string rather than directly to the `.elp` file. After this
  plan, Layer 2 collapses to "ask the gray stream for the start
  byte of each top-level form, hand it to SBCL's source-location
  machinery." Layer 1 (`compile-file` instead of `eval`) is
  unaffected and complementary; Layer 3 (nvim filetype) is
  unaffected.

  Action: when this plan ships, redraft swank Layer 2 around the
  gray stream's position API. Layer 1 can land before or after,
  independently.

## Design notes

### The gray stream as a transducer

SBCL exposes Gray streams via `sb-gray:fundamental-character-input-stream`.
Subclass it with three slots:

- `mmap-ptr` / `mmap-size` — the mapped region.
- `byte-cursor` — current position in the mmap.
- `mode` — `:text`, `:lisp`, or `:expr-body`.
- `synth-buffer` / `synth-pos` — a small string of synthesized
  characters being fed to the reader, plus a cursor into it.
- `position-map` — an ordered list of `(synth-char-count .
  mmap-byte)` checkpoints, updated whenever we transition between
  modes. Used to answer "what `.elp` byte produced the character at
  global stream position P?" — same question the existing
  checkpoints answer, but recorded as the stream emits chars rather
  than reconstructed after the fact.

`stream-read-char` is the only mandatory method. Algorithm:

1. If `synth-buffer` has chars left, return the next one. Bump the
   total-chars-read counter (used as the "reader position" the
   position-map keys off of).
2. Otherwise, depending on `mode`:
   - **`:text`** — call `%memmem` on `mmap-ptr+byte-cursor` for the
     next `<%`. Construct the synth string
     `"(elp::write-output-range elp::*template-ptr* START END)"`
     where START is `byte-cursor` and END is the next `<%` (or
     `mmap-size` at EOF). Update `byte-cursor` past the `<%` (or
     to EOF), peek at the next byte to disambiguate `<%=` vs `<%#`
     vs `<%`, and switch mode to `:lisp`, `:expr-body`, or skip
     to next `%>` for comments. Push a position-map entry.
     Then return the first char of the synth buffer.
   - **`:lisp`** — read the byte at `byte-cursor` from the mmap.
     If it's `%` and the next byte is `>`, advance past both,
     emit the appropriate suffix (just `" "` for a code block,
     `" )) "` for an expr block — see `:expr-body`), switch
     mode to `:text`, and recurse. Otherwise return the byte
     as a character, bump `byte-cursor`.
   - **`:expr-body`** — same as `:lisp` but on entry the mode
     transition synthesized
     `"(let ((elp::*current-template-span* '(C1 C2))) (format t \"~A\" "`
     ahead of the actual code chars. The closing `%>` synthesizes
     `" )) "` and switches back to `:text`.

3. At EOF after the last text span, return `:eof`.

This is one method, ~80 lines. The reader sees a clean stream of
Lisp source; all template-syntax knowledge lives here.

### memmem still does the heavy lifting

The reader **never** char-walks template text. Text-span discovery
is `%memmem` on `<%`. Comment-span skip is `%memmem` on `%>`. The
only chars the reader actually consumes from the mmap are:

- Bytes inside `<% ... %>` blocks (small; bounded by embedded-code
  size — same bound as today's `:code` / `:expr` content
  extraction).
- Synthesized prefix/suffix chunks around each block (constant per
  block).

For a 1MB template with 10 small expression blocks, the reader
sees roughly `(10 × 50-byte synth wrapper) + (10 × small block
content) ≈ 1KB` of characters, while `%memmem` skips through the
~1MB of literal text in 11 vectorized hops. Asymptotically
identical to what `tokenize-mmap` already achieves, but expressed
through one stream interface instead of two stages.

### Position tracking and per-form source locations

`position-map` is an append-only list of `(reader-position .
mmap-byte)` checkpoints — one entry per mode transition. Given a
reader position (which is what reader-error conditions carry, and
what we'd query after each top-level read for source-location
purposes), find the largest entry with `reader-position ≤ query`
and add the offset within the current chunk. Identical math to
today's `body-offset->file-byte`, but the input domain is the
gray-stream's character count rather than a body-string offset.

Two consequences:

- **Error reporting**: `translate-read-error` becomes a one-liner
  that asks the stream for its current `reader-position`, maps it
  to a byte, and routes through the existing `byte->line+column`
  (still `%memchr`-based, unchanged). The synth-string and
  checkpoints-list reconstruction in
  `elp.lisp:body-offset->file-byte` / `translate-read-error` go
  away.

- **Source locations** (swank Layer 2 prerequisite): a top-level
  read loop can record the stream's `reader-position` *before* each
  `read`, map to a `.elp` byte, and stash the result on the form
  via SBCL's source-info hooks. The stream class is the bridge —
  swank Layer 2 doesn't need its own.

### Multi-block spanning constructs

The standard reader is what makes spanning parens work. Concretely:
when the reader encounters `<% (dolist (x xs) %>...` —

1. Top-level read sees the synthesized `(elp::write-output-range
   ...)` for the leading text (if any), reads it, returns one
   form to the driver.
2. Top-level read again. Stream is now in `:lisp` mode.
   Reader sees `(`, calls its `read-list` machinery.
3. `read-list` reads `dolist`, then `(x xs)`, then keeps calling
   `read-char` for the body. Stream encounters `%>` while
   `read-list` is mid-body, transitions to `:text` mode,
   synthesizes the next text span's `(write-output-range ...)`
   call, and feeds those chars back. `read-list` reads them as
   one more form in the dolist body and keeps going.
4. Eventually stream returns `)` from the closing `<% ) %>`,
   `read-list` finishes, top-level read returns the whole
   `(dolist ...)` form.

No special handling. The reader doesn't even know template syntax
exists. This is the structural win over the current approach,
where spanning parens work *because* of string assembly — here
they work because the reader is reading one continuous stream of
synthesized + literal Lisp chars.

### Why a gray stream and not a custom readtable

Considered the alternative: install reader macros on `<` and `%`
to handle the dispatch in a custom readtable. Two problems:

- Reader macros run only at character positions where the reader
  is calling `read-char`. Inside `(dolist ...)`, the reader is
  doing exactly that, so a `<` macro could fire — but the
  spanning case requires the macro to *return forms into the
  surrounding list*, and reader macros return one value. You
  end up needing return-multiple-values-as-splice tricks
  (`(values)` to swallow the form, side-effect into a special
  variable to splice later) that are awkward and fight the
  reader's natural shape.
- Reader macros are global state by default. Even with
  `(let ((*readtable* ...)) ...)`, debugging is harder and the
  abstraction leaks (stack traces show readtable activity).

The gray stream keeps the standard readtable, which means the
forms read from inside `<% ... %>` blocks are read with **exactly
the same reader the user expects** — no surprise macros, no
special syntax inside templates beyond what plain Lisp source
gets.

### Empty files and degenerate inputs

The `mmap` size-0 short-circuit in `render-to-stream` stays. For
templates with no `<%` at all, the gray stream synthesizes one
`(write-output-range *template-ptr* 0 SIZE)` form, the reader
returns it once, EOF on the next read, top-level driver wraps in
`(progn …)` and we're done. No special case needed in the stream.

### What the public API looks like

`render-to-stream` keeps its current signature. Internally:

```lisp
(defun build-render-form (ptr size)
  (let ((stream (make-instance 'template-stream :ptr ptr :size size))
        (forms '()))
    (loop for form = (read stream nil :eof)
          until (eq form :eof)
          do (push form forms))
    `(progn ,@(nreverse forms))))
```

That replaces `tokenize-mmap` + `generate-render-code` together.
The `let` for `context-alist` bindings wraps the result the same
way it does today.

### Risk: what if it's harder than this sketch suggests?

The synth-prefix/suffix bookkeeping for `:expr-body` mode (getting
the `*current-template-span*` byte range right when the stream is
generating the prefix *before* it has read the body's closing
`%>`) is the fiddliest part. Span end is known immediately on
entering the block via a forward `%memmem` for `%>`, so the prefix
can be fully synthesized up front — but verify with a spike on
commit 1 before committing to it.

If the gray-stream design proves harder than expected, the
fallback is a **hybrid two-phase variant**: keep `tokenize-mmap`
as today, but replace the string-assembly in
`generate-render-code` with per-block `(with-input-from-string …
(read s))` calls that feed sexps directly into a `(progn …)`.
Loses spanning-paren support (each `<% ... %>` must parse as
complete forms), but kills string assembly and `read-from-string`
of an assembled string. We don't currently have tests asserting
spanning parens work, so the practical regression is small —
flag this in commit 1 and decide based on what the spike learns.

## Commits

Ordered. Each leaves the tree green (`make test` passes) and is a
single reviewable diff.

1. ✅ **Spike + harness for the gray-stream class.** Add
   `template-stream` as a `sb-gray:fundamental-character-input-stream`
   subclass with the slots above and a working `stream-read-char`
   for `:text` and `:lisp` modes only (no `:expr-body`, no
   comments, no position-map yet). Add unit tests that build a
   small mmap fixture, wrap it, and assert the synthesized
   character sequence matches a hand-written expected string for
   a few inputs (text-only, code-only, alternating). Nothing in
   the engine consumes it yet.
   *Verify:* tests pass; manually `(read stream)` in the REPL on a
   tiny fixture and inspect the resulting form.

2. ✅ **Add `:expr-body` and comment handling to `template-stream`.**
   Extend the stream class to handle `<%=` (synth prefix/suffix
   around the body) and `<%#` (skip via `%memmem` to next `%>`,
   produce no chars). Extend the unit tests from commit 1 to
   cover both. Still nothing in the engine consumes it.
   *Verify:* unit tests assert the stream's output for fixtures
   containing `<%= 1 %>` and `<%# comment %>` matches expected
   strings; reading those streams with `read` produces the
   expected sexps.

3. ✅ **Add position-map; expose `(stream-byte-position stream)`.**
   Track `(reader-position . mmap-byte)` checkpoints on every
   mode transition and at the start of each block. Add a public
   accessor that, given a reader position (e.g. from
   `file-position` on the stream), returns the corresponding mmap
   byte. Unit-test by reading forms from a mixed fixture,
   capturing positions, and asserting they map back to the
   expected `.elp` byte.
   *Verify:* position-map round-trip tests; existing tokenizer
   tests untouched (engine still uses `tokenize-mmap`).

4. ✅ **Switch `render-to-stream` to use the gray stream.** Replace
   the `tokenize-mmap` + `generate-render-code` + `read-from-string`
   pipeline with `build-render-form` (the read-loop sketch above).
   `translate-read-error` collapses to a stream-position lookup.
   `tokenize-mmap`, `generate-render-code`, `body-offset->file-byte`,
   `file-position-of-stream`, and the checkpoints list are deleted.
   Generated sexps are byte-identical for a representative fixture
   set (asserted via `render-form` once that exists from
   `stream-input.md`; until then, asserted via diff on rendered
   output for all fixtures in the test suite).
   *Verify:* `make test` passes (all of it — tokenizer, render,
   error-reporting, the heap-allocation regression test from
   `mmap-tokenize.md`); rendered output of every existing fixture
   is byte-identical to the pre-commit build (`git stash` + diff).

5. ✅ **Spanning-paren regression test.** Add explicit fixtures for
   `<% (dolist (x '(1 2 3)) %><%= x %><% ) %>` and a couple of
   variants (nested `let`, `when`, splitting an `if` across blocks).
   Today's implementation handles these "by accident" via string
   assembly; the new implementation handles them by reader design.
   Lock in the behavior so a future regression is caught.
   *Verify:* tests pass; deliberately break the stream's
   `:lisp` → `:text` transition handling locally and confirm the
   tests fail.

6. ⏭ **Heap-allocation re-baseline. (Deferred — never landed)**
   The `mmap-tokenize.md` regression test this commit was supposed
   to re-baseline was itself never landed (its plan's commit 8
   didn't ship), so there is no test to re-baseline here. Adding a
   fresh `< 2× bytes-consed` assertion is also a known-flaky shape
   (sensitive to GC state, compile caching, fasl loading). The
   render-output assertions across the suite already catch real
   regressions. If a heap budget becomes worth defending later,
   draft it as its own focused plan.

7. ⏭ **Per-form source-location hook. (Deferred — YAGNI)**
   The stated motivation is "sets up the seam swank Layer 2 will
   consume," but swank Layer 2 is in *Future plans* — undrafted,
   unstarted. The load-bearing API (`stream-byte-position`,
   `ts-chars-read`) is already public from commit 3; a future
   consumer can write the read loop they need in three lines.
   Building a public wrapper before the consumer exists locks in
   shape decisions blind. Defer until the swank Layer 2 redraft
   actually pulls on it.

8. ✅ **Drop dead token-structure assertions; refresh README.**
   Post-commit-4 cleanup: `expect-render` had been left with a
   declared-ignored `expected-token-structure` parameter at every
   call site (artifact of the old tokenizer-style assertion). Drop
   the parameter, simplify all 15 engine-test bodies. Rewrite the
   README's *Implementation Notes* section, which still described
   the deleted `tokenize-mmap` pipeline, to describe the gray-stream
   approach.
   *Verify:* full suite green; README reads as documentation of the
   current code, not the deleted code.

9. ✅ **Collapse `render-to-stream` into `render`.** Drop the
   string-returning `render` wrapper; rename `render-to-stream` to
   `render` with the same signature
   `(render pathname context-alist &optional stream)`. One public
   entry point instead of two; callers that want a string wrap in
   `with-output-to-string`. CLI updated to call `render` directly;
   test helper `expect-render` wraps in `with-output-to-string` for
   its string-equality assertion.
   *Verify:* full suite green; `make bin/elp` produces a binary
   that renders templates to stdout.

   Note: this deliberately violates the original Non-goal of "no
   public API surface change." Justified because the user is the
   only consumer right now and the cost of carrying two near-
   identical entry points outweighed the cost of a one-time rename.
   See updated Non-goals below.

10. ✅ **Trim redundant tests; add codegen-shape inspection.**
    Drop 18 tests that didn't pull weight: engine duplicates
    (`expression-only-rendering`, `newlines-in-text`,
    `inline-comment`, `string-concatenation-expression`,
    `list-expression`, `spaces-in-expression`,
    `loop-with-inner-template`); 10 stream-drain tests that
    overspec the internal synth-string format
    (design-time scaffolding for C1/C2, redundant once the engine
    is wired up end-to-end); one trivial defaulting test
    (`stream-byte-position-default-uses-chars-read`). Keep the
    `(read stream)` family — those test the user-facing contract
    "reader produces this sexp" — and the position-map /
    stream-byte-position tests on the public stream API.

    Add `build-render-form-shape`: pins down the exact body sexp
    generated for a small mixed fixture (text + `<%= %>` +
    spanning `dolist` + context binding). Reading the test source
    is the canonical way to see an example of generated code;
    running it catches accidental regressions in the wrapper
    format. Replaces the `--dump-form` CLI flag idea from the
    original Future plans — the inspection happens in the test
    suite where it has fixture context.
    *Verify:* full suite green at 53 checks (down from 70).

## Future plans

When this plan ships, draft these (each its own branch):

- **`stream-input.md` redux.** Per the related-plans note above:
  drop the emit-fn vocabulary, add a string-backed
  `template-stream` subclass that uses `cl:search` instead of
  `%memmem` and synthesizes `write-string` calls instead of
  `write-output-range`. The whole plan gets simpler.

- **`swank-elp-source-locations.md` Layer 2 redux.** Layer 2
  becomes "feed the gray stream's per-form positions into SBCL's
  source-location records." Layer 1 (`compile-file` swap) and
  Layer 3 (nvim filetype) are unaffected and can land in either
  order.

- *(superseded)* `--dump-form` CLI flag for codegen inspection.
  Replaced by the `build-render-form-shape` test in commit 10 —
  reading the test source shows an example of generated code, and
  it doubles as a regression net.

## Non-goals

- Adding new template syntax. Same `<%`, `<%=`, `<%#`, `%>` set.
- UTF-8 correctness fixes. Same caveat as today; same tracking in
  `stream-input.md`'s future-plans section.
- Wiring source locations into SBCL's compiler. The hook lands;
  the swank-side consumption is its own plan.
- Replacing `eval` with `compile`. Worthwhile (caches the compiled
  function per template) but orthogonal to this plan and overlaps
  with swank Layer 1; defer.

### Scope changes during execution

- *Originally non-goal, taken on in commit 9:* changing the public
  API surface. `render-to-stream` was renamed to `render`, and the
  string-returning `render` wrapper was deleted. Justified because
  the user is the only current consumer; carrying two near-identical
  entry points cost more than a one-time rename.
