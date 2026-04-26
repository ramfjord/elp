# Reader-aware close-delim scan

## Goal

Stop closing `<% … %>` prematurely when the body contains a `%>`
sequence inside a Lisp string literal, line comment, character
literal, or block comment. By the end of this branch, all of these
render correctly:

```erb
<% (format t "%>") %>
<% (format t "-%>") %>
<%= (format t "~A" "%>") %>
<% ; comment with %> in it
   (do-thing) %>
<% #| %> still inside |# (do-thing) %>
<% (format t "~A" #\") %>
```

The remaining unsupported edge case is `|vertical-bar-symbol with %>|`
notation, which is rare enough in templates to leave as a documented
limit.

## Context

The README's *Whitespace trim* subsection currently warns that `%>`
(and `-%>`) inside Lisp string literals will end the tag — a real bug
that pre-exists the trim work and was inherited by the trim plan. The
root cause is `ts-find-close-delim`'s use of `memmem` and the
`:lisp`/`:expr-body` byte loop's byte-by-byte `%>` check: both treat
the source as raw bytes with no Lisp lexical context.

Templates routinely call `format` with delimiter-like format strings.
Anyone touching that pattern hits the bug immediately. Fixing it
narrows the gap between "works in ERB intuition" and "works in ELP" by
a lot.

## Related plans

Checked `./plans/` on 2026-04-25:

- `mmap-tokenize.md`, `reader-macro-codegen.md` — both shipped. This
  plan touches the same `template-stream` close-detection paths the
  reader-macro-codegen plan introduced (`ts-find-close-delim`, the
  `:lisp`/`:expr-body` byte loop) but only narrows when those signal
  "close found." No design conflict.
- `stream-input.md` — adds string/stream input. Independent: this plan
  scans bytes from `ptr` regardless of whether the source came from
  mmap or a slurped string. Once the string-backed `template-stream`
  subclass lands, the scanner here applies to both with no change.
- `swank-elp-source-locations.md` — source-location plumbing. The
  scanner shifts which byte is reported as the close position only in
  cases that previously gave the *wrong* close position; correct cases
  are unchanged. No conflict.
- `trim-mode` (just shipped on this branch) — the trim implementation
  computes close position via the same `ts-find-close-delim` /
  byte-loop. The new scanner subsumes both call sites; the trim check
  (byte before close is `-`) keeps working unchanged.

No sequencing dependency. Safe to ship in any order.

## Design notes

**One scanner, two callers.** Add a pure
`ts-scan-close (ptr from size)` that walks bytes from FROM, tracking
Lisp lexical state, and returns the byte offset of the next `%>` not
inside a string / line comment / char literal / block comment, or NIL.
Use it in two places:

1. `<%=` and `<%#` dispatch in `:text` mode — replaces the current
   `ts-find-close-delim` call. Already used today to find the body
   span for the whitespace-only check and the runtime span literal.

2. `<%` plain-code dispatch — computes close position once when
   entering `:lisp` mode, stored on the stream as a new slot
   `lisp-close-pos`. The `:lisp`/`:expr-body` byte loop then emits
   body bytes until `cur == lisp-close-pos`, at which point it
   handles close (and trim-check) the same as today. No more
   per-byte `%>` check.

This is structurally simpler than tracking lex state byte-by-byte on
the stream during reads: lex state lives only inside the scanner, not
across read calls.

**State machine.** Five states inside the scanner:

- `:default` — `"` → `:string`; `;` → `:line-comment`; `#|` →
  `:block-comment` (nesting depth 1); `#\` → consume the next byte
  (the char-literal payload) and stay `:default`; `-%>` or `%>` →
  return close position; else advance one byte.
- `:string` — `\` → consume the next byte (escape); `"` → `:default`;
  else advance.
- `:line-comment` — `\n` → `:default`; else advance.
- `:block-comment` (with depth counter) — `#|` → depth+1; `|#` →
  depth-1, when 0 → `:default`; else advance.

`#\X` only consumes one byte after `#\` — enough to neutralize the
common foot-guns (`#\"`, `#\;`, `#\%`, `#\(`). Multi-char named
characters like `#\Newline` are safe because their constituent bytes
don't include any of the trigger characters.

**Trim composition.** Trim detection is unchanged: after the scanner
returns close-pos, check whether `(byte-at (1- close-pos))` is `-`.
Since the scanner ignores `%>` inside strings/comments, the close-pos
it returns is always the *real* close, so the trim check applies to
the real close.

**Performance.** `ts-find-close-delim` was vectorized via `memmem`;
the new scanner is byte-by-byte. Tag bodies are typically tens of
bytes, so the cost is negligible. Literal text spans (the long ones)
still use `memmem` to find `<%`, unchanged.

## Commits

1. **Add `ts-scan-close` with strings, line comments, char literals.**
   Pure function operating on `ptr/from/size`, returning the byte
   offset of the next `%>` not inside `"…"`, `;…\n`, or `#\X`. No
   call sites yet — exercise via direct unit tests.
   *Verify:* unit tests on small ASCII buffers covering each state
   (string with `\\"` escape, line comment, `#\"`, `#\(`, plain
   close, no-close-found returns NIL).

2. **Replace `ts-find-close-delim` with `ts-scan-close` in the `<%=`
   and `<%#` dispatch.** Both call sites already use the returned
   close position the same way; just swap the call. Delete
   `ts-find-close-delim` once unreferenced.
   *Verify:* `expect-render` tests for
   `<%= (format nil "%>") %>` rendering `"%>"`, and a comment
   containing `%>` (degenerate but consistent).

3. **Pre-compute close position for `<%` plain code blocks.** Add a
   `lisp-close-pos` slot on `template-stream`; populate it in the
   `<%` dispatch via `ts-scan-close`; rewrite the `:lisp` /
   `:expr-body` byte-loop close check to fire on
   `cur >= lisp-close-pos` instead of inspecting the next two/three
   bytes. The trim check (byte at `(1- lisp-close-pos)` is `-`)
   moves with it.
   *Verify:* `<% (format t "%>") %>` and `<% (format t "-%>") %>`
   render correctly; existing trim tests still green.

4. **Add `#|…|#` block comment support to `ts-scan-close`.** With
   nesting depth counter.
   *Verify:* `<% #| %> still inside |# (setf x 1) %>` closes at the
   right `%>`; nested `#| #| inner |# outer %> |#` also handled.

5. **README: narrow the close-delim caveat.** Drop the broad
   "string-literal" warning; replace with a one-liner noting that
   `|vertical-bar-symbol|` notation is the remaining unsupported
   edge.
   *Verify:* `make test` green; eyeball the rendered README section.

## Future plans

- **Vertical-bar symbol notation (`|sym with %>|`).** Add `|…|` as a
  fifth scanner state. Low value (vanishingly rare in templates) but
  the scanner is the right place to add it if someone hits it.
- **Reader-state-aware error reporting.** When a tag body is invalid
  Lisp (unbalanced `(`, etc.), the current line/col points at the
  body start, not the offending token. Orthogonal to this plan but
  the scanner's per-byte state walk could feed a more precise
  position.

## Non-goals

- Full Lisp reader fidelity. The scanner approximates the reader
  enough to find the right `%>`; it doesn't try to be a parser. Any
  syntax that requires reader-macro dispatch or package-aware reads
  to disambiguate is out of scope.
- Changing the dispatch shape for `<%=` or `<%#`. They keep the
  whitespace-only-skip / runtime-span-literal behavior they have
  today; only the source of `close-pos` changes.
- Removing the `memmem`-based `<%` open scan. The open delimiter is
  unambiguous — no Lisp lexical context to track.
