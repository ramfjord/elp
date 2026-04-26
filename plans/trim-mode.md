# ERB-style trim mode

## Goal

Per-tag opt-in whitespace trimming, matching ERB's `-` flag:

- `-%>` strips a single trailing newline (and any preceding `\r`)
  immediately after the closing delimiter.
- `<%-`, `<%-=`, `<%-#` strip ASCII spaces and tabs immediately
  *preceding* the opening delimiter, back to (but not including) the
  prior newline.

By the end of this branch, this template:

```erb
<% (dolist (x xs) -%>
  - <%= x %>
<%- ) -%>
```

with `xs = (a b c)` renders as:

```
  - a
  - b
  - c
```

instead of today's output, which has a blank line at the top, doubled
newlines between iterations, and a trailing blank line.

## Context

The README's *Future Enhancements* section already lists "Whitespace
trimming modes (`%-`, `-%`)" as desired. Multi-tag constructs like
`<% (dolist ...) %>` currently force authors to either produce ugly
output with stray newlines or to write awkward one-line templates.
This is the most common ergonomic complaint about ERB-style engines and
the cheapest one to fix here, because the tokenizer/stream is the only
place that needs to change — codegen and rendering are untouched.

## Related plans

Checked `./plans/` on 2026-04-25:

- `mmap-tokenize.md`, `reader-macro-codegen.md` — both shipped (the
  README and recent commits reflect the as-shipped state). This plan
  modifies the same `template-stream` state machine they introduced,
  but only inside the `:text` dispatch and the `:lisp`/`:expr-body`
  close-detection — no overlap with their goals.
- `stream-input.md` — adds string/stream input. Independent of trim:
  trim runs against `ptr`/`size`, not against the source-acquisition
  layer. Whichever lands first, the other only needs trivial merge.
- `swank-elp-source-locations.md` — source-location plumbing. Trim
  shifts byte ranges that go to `write-output-range` but does **not**
  alter the position-map checkpoints (those anchor at code/expr body
  starts, which trim doesn't touch). No conflict.

No sequencing dependency. Safe to ship in any order.

## Design notes

**Where trim happens.** All trim logic lives in
`elp.lisp`'s `template-stream` (the `:text` mode dispatch and the close
detection in `:lisp`/`:expr-body`). The generated render form is
unchanged — `write-output-range` calls just cover slightly different
byte ranges, and a single trailing-newline byte is sometimes skipped
between blocks. Codegen, error translation, and the position-map are
untouched.

**Open trim (`<%-`).** When the byte after `<%` is `-`, scan backward
from the `<%` position over ASCII space/tab bytes. If that scan hits a
newline (or the start of the file), the text emit's end is moved to
that earlier position. If the scan hits a non-whitespace byte before a
newline, no trimming happens — open trim only nukes pure indentation,
not real content. The `-` is consumed as part of the opening
delimiter; dispatch on the byte *after* `-` (`=`, `#`, or code-start)
proceeds as today.

**Close trim (`-%>`).** When the bytes immediately before `%>` are
`-`, the body ends one byte earlier (so `-` is not part of the Lisp
form), and after consuming `%>` the byte cursor is advanced past at
most one `\r\n` or `\n` before re-entering `:text` mode.

For `<%=` we already pre-scan to `%>` via `ts-find-close-delim` to do
the whitespace-only check; that scan needs to recognize the `-`
immediately before `%>` and adjust the body end accordingly. For `<%`
and `<%#` the close is detected byte-by-byte inside `:lisp` /
comment-skip; that check needs to fire one byte earlier when the
upcoming three bytes are `-%>`.

**False triggers inside Lisp code.** `-%>` could in principle appear
inside a string literal, e.g. `<% (format t "-%>") %>`. The existing
implementation already treats bare `%>` as the close delimiter
regardless of reader state (a documented limitation — same as ERB),
so applying the same rule to `-%>` doesn't make this worse. Call this
out in the README alongside the existing `%>` caveat.

**Non-trim is the default.** Plain `<% %>` and `<%= %>` behave
exactly as today. No template needs to change.

## Commits

1. **Recognize `-%>` close-trim in all three tag flavors.** Teach
   `ts-find-close-delim` (or a thin variant returning both the `%>`
   position and a close-trim flag) to detect a `-` immediately before
   `%>`. In `:lisp` and `:expr-body`, end the body one byte earlier
   when the upcoming three bytes are `-%>`; after consuming the close,
   skip an optional `\r` and at most one `\n` before re-entering
   `:text`. For `<%=`, exclude the `-` from the body span passed to
   the whitespace-only check and the synth-prefix range. `<%#` close
   trim falls out of the same close-detection change.
   *Verify:* new tests for `<% ... -%>\n`, `<%= ... -%>\n`, and
   `<%# ... -%>\n` confirming the trailing newline is dropped from
   output; a regression test confirming bare `%>` still works
   unchanged.

2. **Recognize `<%-`, `<%-=`, `<%-#` open-trim.** In the `:text`
   dispatch, when the byte after `<%` is `-`, walk backward from the
   `<%` position over `[ \t]` bytes. If the walk reaches a newline or
   the start of the file, shorten the preceding text emit's end to
   that earlier position; otherwise leave the emit unchanged. Then
   skip the `-` and dispatch on the next byte exactly as today.
   *Verify:* tests covering "`  <%- ... %>`" at start of line (indent
   stripped), at start of file (indent stripped), and after non-
   whitespace on the same line (no stripping). A combined test
   exercises `<%-` + `-%>` together inside a `dolist` to confirm the
   intended ergonomic outcome from the *Goal* example.

3. **Document trim mode in README; remove from Future Enhancements.**
   Add a *Whitespace trim* subsection under *Syntax* showing the
   `<%-` / `-%>` forms and the `dolist` example. Note the same
   `%>`-inside-strings caveat applies to `-%>`. Drop the "Whitespace
   trimming modes" bullet from *Future Enhancements*.
   *Verify:* `make test` still green; eyeball the rendered README
   section.

## Future plans

- Global trim-mode flag (ERB's `>` and `<>` modes) that strips
  newlines around lines containing only ELP tags, without per-tag
  opt-in. Useful for templates where every tag should trim.
- A `--trim` CLI flag that selects the global mode for a single
  render.

## Non-goals

- Stripping arbitrary whitespace, only `[ \t]` before the open and a
  single newline after the close. ERB's behavior; matching it keeps
  the rule learnable.
- Treating `-%>` inside Lisp string literals as not-a-close. The
  existing engine already has the same limitation for bare `%>`;
  fixing both is out of scope here.
- Configurable trim characters or alternate delimiters.
