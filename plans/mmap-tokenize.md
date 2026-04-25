# Tokenize directly against the mmap (no slurp)

## Goal

Tokenization stops materializing the whole file as a Lisp string.
Instead, the renderer opens the mmap **once**, tokenizes by scanning
the mapped bytes with glibc's vectorized `memmem` for the `<%` /
`%>` delimiters, then runs codegen against those byte offsets and
evals the body — all reusing the same mmap.

By the end of this plan:

- `tokenize-file` is gone; in its place is `tokenize-mmap (ptr size)`
  which never allocates a copy of the source.
- A new public `render-to-stream pathname context-alist &optional
  stream` becomes the streaming primitive. The existing `render`
  is reduced to a thin `with-output-to-string` wrapper around it,
  for callers who genuinely want the output as a string. The CLI
  switches to `render-to-stream` so its output truly streams —
  today it accumulates the whole rendered result into a Lisp
  string and *then* prints it (`cli.lisp:74-75`), which silently
  defeats the mmap savings on the output side.
- `render-to-stream` opens the mmap once at the top, passes
  `ptr`/`size` into the tokenizer, generates code, evaluates it
  inside the same `unwind-protect`, and never opens or reads the
  file twice.
- When the destination stream is a real `sb-sys:fd-stream` (the
  CLI's `*standard-output*`, or any stream the caller opens), text
  ranges go to the kernel via direct `write(2)` calls on the
  mmap'd pages — the zero-copy path that `write-output-range`
  already implements but that `with-output-to-string` masked from
  every actual caller.
- A multi-MB template tokenizes in time roughly proportional to the
  number of delimiters, not to the file size — because memmem skips
  through non-delimiter regions at SSE/AVX speed and we never copy
  the bytes.
- `byte->line+column` reads from the mmap instead of re-opening the
  file.
- **Lisp-heap allocation during render is independent of file size**
  — it scales with token count and total embedded-code length,
  not template length. Asserted by a regression test (see commit
  7 below). Process RSS will still grow with file size as the
  kernel pages mmap'd regions in; that's page cache, not heap.

## Context

`tokenize-file` today does two wasteful things on the file path:

1. Slurps the whole file into a Lisp string with `read-sequence` so
   `cl:search` can scan it. For a large template that's an
   allocation + copy of the entire file.
2. The renderer then mmaps the same file *again* inside the
   generated sexp. So we read the file twice (once through the FS
   into the heap, once through mmap) before a single byte of output
   is written.

The mmap path already exists and is the fast path for *output*.
Extending it to cover tokenization is mostly a matter of pointing
the scanner at the mapped region instead of a Lisp string. glibc's
`memmem` is SSE4.2/AVX2-vectorized and is exactly the primitive
we want for finding 2- and 3-byte ASCII needles in a large
haystack — it's the same kind of "system call to seek for the
token boundary patterns in some kind of vectorized instruction"
this plan was prompted by, just exposed as a libc function rather
than a syscall.

This is also a structural cleanup. The current flow —
`tokenize-file` opens + slurps + closes the file, then the
generated sexp opens + mmaps + closes it again — is two independent
file-acquisition paths that would each need to be generalized for
the string/stream backends in `stream-input.md`. Collapsing the
file path to a single mmap-once flow makes that later
generalization simpler, not harder.

## Related plans

- **`stream-input.md`** — drafted, not in flight. Adds
  `render-string` / `render-stream` and a CLI stdin path. **This
  plan should land first.** Reasons:

  - That plan's commit 1 generalizes `byte->line+column` to take a
    source string. This plan instead generalizes it to read from
    the mmap (ptr+size). Both are pure refactors of the same
    function; doing this one first means stream-input's commit 1
    becomes "add a *second* code path for in-memory strings"
    rather than "rewrite a function that's about to be rewritten
    again."

  - That plan's commit 2 (emit-fn factoring) is unaffected by this
    work and remains a clean refactor on top.

  - The string and stream backends will need their *own* tokenizer
    entry point (no mmap available), so they'll grow a
    `tokenize-string` sibling. The two backends genuinely diverge
    at the tokenizer level — that's expected; templates from
    stdin are small, templates on disk can be large, the hot path
    matters only for the file case.

  Action: when this plan ships, re-draft `stream-input.md` so
  commit 1 is "add `tokenize-string` for the in-memory backends"
  rather than "generalize `byte->line+column` to take a string."

- **`swank-elp-source-locations.md`** — independent. Its
  checkpoints/source-location work consumes the byte offsets the
  tokenizer produces; the tokenizer's *internals* are opaque to
  it. No conflict.

## Design notes

### `memmem` as the scanning primitive

`memmem(haystack, hlen, needle, nlen)` is a glibc extension (also
on FreeBSD and modern macOS, but ELP targets SBCL/Linux), declared
in `<string.h>`. It returns a pointer into the haystack or NULL.
glibc's implementation uses SSE4.2 `pcmpestri` / AVX2 dispatch for
needle lengths ≤ 16, which covers our 2- and 3-byte delimiters
trivially.

CFFI binding sketch:

```lisp
(defun %memmem (haystack-ptr haystack-len needle needle-len)
  "Return byte offset of NEEDLE in HAYSTACK-PTR[0,HAYSTACK-LEN), or NIL."
  (cffi:with-foreign-string ((nptr nbytes) needle :encoding :ascii
                                                  :null-terminated-p nil)
    (declare (ignore nbytes))
    (let ((found (cffi:foreign-funcall "memmem"
                   :pointer haystack-ptr :size haystack-len
                   :pointer nptr         :size needle-len
                   :pointer)))
      (and (not (cffi:null-pointer-p found))
           (- (cffi:pointer-address found)
              (cffi:pointer-address haystack-ptr))))))
```

Needles (`<%`, `<%=`, `<%#`, `%>`) are constant ASCII; we can hoist
the foreign-string allocation into top-level `defparameter`s of
foreign buffers if it shows up in profiles. Don't bother in the
first cut.

Portability footnote: macOS got `memmem` in 10.7+, FreeBSD has it.
If non-Linux support ever matters, fall back to a tight Lisp loop
calling `memchr` for the first byte and doing a 1–2 byte tail
compare. Keep this for a follow-up plan; not in scope here.

We also need `memchr` (single-byte search) for newline counting in
error reporting — see below. `memchr` is POSIX, even more
aggressively vectorized than `memmem` (glibc ships hand-tuned
AVX2/AVX-512 versions), and the natural primitive for "find next
`\n`." Same CFFI shape as `%memmem`, just with a byte arg
instead of a needle pointer.

### Token shape stays the same

Tokens stay `(type content start end content-start content-end)`,
keeping checkpoints / `byte->line+column` / error reporting
unchanged. What changes is *how* the fields are filled:

- `:text` and `:comment` tokens have `content = NIL` — nobody
  reads it on the file path (codegen only uses the offsets to emit
  `write-output-range`), and not allocating it is the whole point.
- `:code` and `:expr` tokens still need `content` as a Lisp string,
  because `read-from-string` consumes it during codegen. Extract
  via `cffi:foreign-string-to-lisp` on just the
  `[content-start, content-end)` byte range. That's an
  allocation, but bounded by the size of the embedded code, not
  the size of the template.

The `string-trim` we currently do on `:code`/`:expr` content stays
where it is; it operates on the small extracted Lisp string.

### Single-mmap render flow

Current `render` (file path):

```
tokenize-file pathname        ; opens, slurps, closes
generate-render-code …        ; emits a sexp that opens+mmaps
eval sexp                     ; runs, then closes mmap
```

New flow:

```
multiple-value-bind (ptr size fd) (%mmap-open pathname)
  unwind-protect
    let tokens = tokenize-mmap ptr size
    let sexp,checkpoints = generate-render-code tokens context
    handler-bind (… byte->line+column-mmap ptr size byte …)
      eval sexp     ; sexp uses ptr lexically, no longer opens its own
    %mmap-close ptr size fd
```

This drops `%mmap-open` / `%mmap-close` out of the generated sexp
entirely; the sexp becomes a plain `progn` of write/format/code
forms referencing the lexical `ptr`. `eval` is called in the null
lexical environment, so `ptr` must be made available another way
— the simplest is a special variable bound around `eval`:

```lisp
(let ((*template-ptr* ptr))
  (declare (special *template-ptr*))
  (eval sexp))
```

…and codegen emits `(elp::write-output-range elp::*template-ptr*
S E)` instead of `elp::ptr`. This keeps the sexp self-contained
and free of free lexical references, at the cost of one
special-variable indirection per text-token write — negligible
versus the `write(2)` syscall that follows.

(Alternative considered: keep the `multiple-value-bind` wrapper
inside the generated sexp but have it reuse an existing fd via a
new `%mmap-attach` rather than re-opening. Rejected — special
variable is shorter and matches how `*current-template-span*`
already works.)

### Error reporting reads the mmap too — also via libc

`byte->line+column` currently re-opens the pathname and counts
characters one at a time up to the byte offset. With the mmap
already in scope, the natural rewrite is a `memchr`-driven loop:
repeatedly call `%memchr(ptr+cursor, byte-offset-cursor, '\n')`,
incrementing the line counter on each hit, until the next hit is
past the target offset; then column = `byte-offset - last-newline`.

This is strictly faster than a per-byte Lisp loop (one foreign
call per *line* in the prefix, not per *byte*), and on a large
template with errors near the bottom that's a meaningful
difference — the line-count work becomes vectorized like the
tokenizer scan.

`memchr` is POSIX and on every platform that has `mmap`, so this
adds no portability constraint beyond what we've already
committed to. ASCII-only caveat for column counting is the same
as today (UTF-8 audit is in `stream-input.md`'s future-plans
section).

### Why streaming is the primitive, string-return is the wrapper

Today's `render` returns a string by `with-output-to-string`-ing
around the entire eval. That has two consequences worth being
explicit about:

1. **Output materializes in Lisp memory regardless of size.** A
   1GB template produces a 1GB Lisp string before the caller
   sees a single byte. For any caller that's going to write the
   result to a stream anyway (the CLI, an HTTP handler, a file
   exporter), that's a strict regression vs. just letting the
   template engine write to the destination directly.

2. **The zero-copy `write(2)` path in `write-output-range` never
   fires from real callers.** It's gated on
   `*standard-output*` being an `sb-sys:fd-stream`, but
   `with-output-to-string` always rebinds it to a
   string-output-stream first. So the fast path is effectively
   dead code today, and the mmap+memmem work in this plan would
   be undermined on the output side without inverting the API.

The fix is to invert: expose the stream-taking primitive and
keep the string-returning wrapper for callers who want it.

```lisp
(defgeneric render-to-stream (input context-alist &optional stream))

(defun render (input context-alist)
  (with-output-to-string (s) (render-to-stream input context-alist s)))
```

The CLI switches to `render-to-stream` with the default
`*standard-output*` (which, in a `sb-ext:save-lisp-and-die`
binary, is a real fd-stream). For library callers, `render` keeps
working unchanged.

This is also what makes the heap-allocation regression test
clean: the test calls `render-to-stream` against a
`(make-broadcast-stream)` sink and measures
`get-bytes-consed`. No private/test-only API.

### Asserting "no full-file load" mechanically

Two layers, because RSS and Lisp heap measure different things:

- **Lisp heap (deterministic, in the test suite).**
  `sb-ext:get-bytes-consed` returns total bytes ever consed by
  this thread; deltas over a `render` call are a clean measure of
  Lisp-side allocation. The plan claim is: heap delta is bounded
  by `O(token-count + sum-of-code-content) + O(output-size if
  output stream is a Lisp string)`. So we test it under
  conditions that hold the second term constant: render to a
  null sink and vary file size.

  SBCL's `(make-broadcast-stream)` with no targets accepts writes
  and discards them — exactly the sink we need. Tests call the
  public `render-to-stream` directly with a broadcast-stream as
  the destination.

- **Process RSS (smoke test, documented).** Belongs with the
  bench in commit 6, not the regression suite — RSS depends on
  kernel page-cache behavior and a CI runner's memory pressure,
  so any threshold is flaky. Document the recipe (`/usr/bin/time
  -v ./bin/elp big.elp > /dev/null`) and the expected shape:
  small steady-state working set, RSS dominated by page cache
  that the kernel will reclaim on demand.

### Empty files

`mmap` of a zero-length file returns `EINVAL` on Linux. Special-case
size 0 in `render`: skip mmap entirely, emit nothing, return "". One
branch; tested.

## Commits

Ordered. Each leaves the tree green (`make test` passes) and is a
single reviewable diff.

1. **Add `%memmem` and `%memchr` CFFI wrappers + tests.** Pure
   addition; nothing else uses them yet. Internal helpers, not
   exported. Both return a byte offset or NIL.
   *Verify:* unit tests that build a foreign buffer with known
   contents and assert each wrapper finds / fails to find expected
   needles/bytes, including at the very start, very end, and
   overlapping matches.

2. **Add `tokenize-mmap (ptr size)` alongside `tokenize-file`.**
   New function with the same return shape. `:text`/`:comment`
   tokens have `content = NIL`; `:code`/`:expr` tokens extract via
   `foreign-string-to-lisp` on the content byte range. Uses
   `%memmem` for delimiter scans. `tokenize-file` still exists and
   is still the path `render` uses.
   *Verify:* parametrize the existing tokenizer tests over both
   functions (call `tokenize-file`, then mmap the same fixture and
   call `tokenize-mmap`, assert the two token streams are equal
   modulo `:text`/`:comment` content being NIL in the mmap version).

3. **Introduce `render-to-stream` and switch the engine to a
   single-mmap, streaming flow.** New exported
   `render-to-stream pathname context-alist &optional stream`
   becomes the primitive: opens the mmap, calls `tokenize-mmap`,
   runs codegen, binds `*template-ptr*`, evals the body writing
   directly to `stream` (defaults to `*standard-output*`).
   Generated sexp loses its inner `%mmap-open` / `%mmap-close`
   and emits `*template-ptr*` instead of `ptr`. `render`
   collapses to `(with-output-to-string (s) (render-to-stream
   input ctx s))` — same shape, same return value, all existing
   callers and tests unaffected. Empty-file branch added.
   `tokenize-file` becomes unused on the render path but stays
   exported so external callers aren't broken.
   *Verify:* `make test` (40/40) still passes; `cat` a large
   fixture through the renderer and diff the output against the
   pre-change build to confirm it's byte-identical.

4. **Rewrite `byte->line+column` to scan the mmap with `%memchr`.**
   Takes `(ptr size byte-offset)`; finds newlines via repeated
   `%memchr` calls so the prefix scan is vectorized like the
   tokenizer. Caller in `render` passes the live ptr/size from
   the surrounding `multiple-value-bind`. `translate-read-error`
   likewise.
   *Verify:* the existing error-reporting tests
   (`elp-template-error` line/column assertions) still pass
   unchanged.

5. **Switch the CLI to `render-to-stream`.** `cli.lisp:74-75`
   today does `(let ((result (render …))) (write-string result))`,
   accumulating the entire rendered output into a Lisp string
   before printing — which silently defeats the streaming work
   in commit 3. Replace with `(render-to-stream (pathname
   template-file) context)`, which writes through to
   `*standard-output*` (an `sb-sys:fd-stream` in the saved
   binary) and triggers `write-output-range`'s zero-copy
   `write(2)` path for text ranges.
   *Verify:* existing CLI smoke test (`./bin/elp template.elp`)
   produces byte-identical output. Manual: run
   `/usr/bin/time -v ./bin/elp big.elp > /dev/null` on a fixture
   generated by commit 6's helper; peak RSS should be a small
   constant + the kernel's page-cache pressure, *not* file-size
   plus output-size as it is today.

6. **Delete `tokenize-file` and the stale `parse-template` /
   `render-template` / `render-string` legacy helpers.**
   `tokenize-file` is unused after commit 3; the bottom of
   `elp.lisp` (lines 306–411) is dead code from an earlier
   implementation. Remove from `:export`. This is a behavior-free
   cleanup that shrinks the file and removes the "two ways to do
   it" footgun.
   *Verify:* `make test` passes; `grep -r tokenize-file` /
   `grep -r parse-template` returns nothing under `cli.lisp` or
   `elp-test.lisp`.

7. **Bench + document the win.** Add a small generator helper
   (committed as code, not as a megabyte blob) that produces a
   large fixture on demand, plus a one-shot bench function
   `(elp::bench-render path)` that times `render` over it.
   Record numbers in the commit message and add a one-paragraph
   "Performance" note to `README.md` describing the mmap+memmem
   design. Document the manual RSS smoke-test recipe
   (`/usr/bin/time -v ./bin/elp big.elp > /dev/null`) so future
   contributors can sanity-check process working set without
   needing a flaky CI assertion.
   *Verify:* bench function runs and reports timings; ad-hoc
   comparison vs. a `git stash` of the pre-plan code shows the
   expected improvement.

8. **Heap-allocation regression test.** New FiveAM test that, in
   a `before` setup, generates two fixtures via the helper from
   commit 7 — say 1MB and 50MB, both with the same handful of
   embedded `<%= … %>` — into a temp directory. For each:
   capture `(sb-ext:get-bytes-consed)` before, call
   `render-to-stream` against `(make-broadcast-stream)` (a sink
   that discards), capture after, record the delta. Assert the
   50MB delta is *not* meaningfully larger than the 1MB delta —
   concretely, within a small constant factor (e.g. ≤ 2×).
   Cleanup the temp fixtures in an `after` hook.
   *Verify:* test passes after commits 1–6; deliberately
   regress (e.g. swap `tokenize-mmap` back for `tokenize-file`
   in `render-to-stream` locally) and confirm the test fails.
   Don't keep the regression — just confirm the assertion has
   teeth.

## Future plans

When this plan ships, draft these (each its own branch):

- **`stream-input.md` redux.** Re-draft on top of this plan: add
  `tokenize-string` (Lisp-string equivalent of `tokenize-mmap`) for
  the in-memory backends, plus the `render-string` /
  `render-stream` / CLI stdin work from the existing draft. The
  emit-fn factoring (current commit 2 of `stream-input.md`) still
  applies.

- **Hoist needle foreign-strings.** If profiling shows `%memmem`
  spending non-trivial time in `with-foreign-string`, allocate the
  four needle buffers once at load time and reuse.

- **Non-glibc fallback.** Lisp-side `memchr`-driven scanner for
  platforms without `memmem`. Only worth doing if someone
  actually wants ELP on macOS/Windows.

## Non-goals

- Any change to the public API surface (`render`, error condition,
  exported symbols) beyond removing the legacy `parse-template` /
  `render-template` / `render-string` symbols that are clearly
  vestigial. Replacement string-rendering API lives in
  `stream-input.md`.
- True streaming over an unseekable input (pipe / socket). This
  plan is specifically about the *file* path; streams are
  inherently slurp-then-tokenize and that's fine — see
  `stream-input.md`.
- UTF-8 correctness fixes. Same ASCII-delimiter assumption as
  today, same line/column character-counting caveat. Tracked in
  `stream-input.md`'s future-plans section; addressing it here
  would balloon the diff.
