# Swank-aware `.elp` editing with source locations

Tracked as GitHub issue #5.

## Goal

Errors raised from code inside template tokens carry source locations
that resolve to the originating `.elp` file and line/column — so
vlime's debugger jump-to-source, backtraces, compiler notes, and
`swank:find-source-location` all land in the template, not in a
synthetic in-memory form. Same data flowing through the `eval_swank`
MCP transport, so agentic Lisp work on `.elp` files benefits too.

Complementary to `elp-template-error`, which translates engine-level
and runtime errors with file/line/column from the engine's side.
This plan is about the *host* SBCL view.

## Approach

Layered, errors-first.

### Layer 1 — compile under a `.elp` pathname

`compile-template` calls `(compile nil …)` on a freshly assembled
lambda, so SBCL records no source for the resulting function. Make
SBCL believe the lambda came from the `.elp` file. Two paths:

- **Path A:** bind `*compile-file-pathname*` /
  `*compile-file-truename*` around the `compile` call. Cheapest
  patch — needs a spike to confirm SBCL actually attaches those
  values to the resulting code-component when the underlying call
  is `compile` rather than `compile-file`.
- **Path B:** print `template-code` to a temp `.lisp`, `compile-file`
  it with `*compile-file-pathname*` set to the `.elp`, load the
  fasl. Heavier but the path SBCL definitely honors.

Try A first; fall back to B if `swank:find-source-location` doesn't
pick up the pathname.

Side delta to bundle: install `*current-template-span*` around plain
`<% … %>` bodies too, mirroring `<%= … %>`. Plain code tags
currently fall back to byte 0 when they raise. Few lines in
`ts-parse-tag-chunk`'s `:code` arm.

### Layer 2 — per-form source locations

Goal: errors point at the specific form, not just the file. Two
routes; pick after Layer 1.

- **Route A — finer `*current-template-span*`.** Wrap each top-level
  form inside a tag with its own span, not just the tag as a whole.
  Engine-side only; `elp-template-error` gets sharper, but SBCL's
  source-locations still see nothing. Good enough for any consumer
  that goes through `elp-template-error` (including `eval_swank`);
  not enough for vlime's goto-source on a compile-time warning.
- **Route B — bridge into SBCL's source-info.** `template-stream`'s
  `position-map` already maps reader-pos → mmap-byte. Two
  sub-options:
  - **Custom read-with-locations.** Read forms off the
    `template-stream` one at a time, capture `chars-read` before
    each `read`, map to `.elp` byte via `stream-byte-position`,
    attach an `sb-c::source-location` to each form before handing it
    to the compiler. Capture is essentially free; the attach is the
    spike.
  - **Walk-and-tag.** Extend the existing `compile-form` walk
    (`hu.dwim.walker` already produces an annotated AST per node) to
    also emit source-location tags. Additive to a walk that already
    happens.

Route A is incremental; Route B is the one `swank:find-source-location`
actually consumes. Land in that order if both are wanted.

## Open questions

- Does Path A populate source-info that survives to
  `swank:find-source-location`, or only error-printing?
- Does SBCL preserve injected source-locations through `compile-file`
  → `load` for `swank:find-source-location` use, or only during the
  compile? Determines whether Layer 2 helps M-. on
  template-defined functions, or only error reports.

## Related plans

- `elp-nvim-filetype.md` — editor-side counterpart (issue #4).
  Independent for the basics; M-. on symbols *defined inside* a
  template only resolves to the right `.elp` line once Layer 2 lands.

## Non-goals

- LSP. Rides on swank.
- Editor-side region handling — `elp-nvim-filetype.md`.
- Templating-DSL-aware features (e.g. completing context-alist keys).
