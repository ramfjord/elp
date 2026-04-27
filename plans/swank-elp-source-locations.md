# Swank-aware `.elp` editing with source locations

## Goal

**Errors point to the right `.elp` line.** Compile-time warnings and
runtime errors raised from code *inside* template tokens carry source
locations that resolve to the originating `.elp` file and line/column
— so vlime's debugger ("source" / `\sl` jump-to-source), backtraces,
and compiler notes all land in the template, not in a synthetic
`read-from-string` buffer with no useful position.

Tracked as GitHub issue #5.

Complementary to `elp-template-error`, which already handles failures in
the *engine* layer (tokenizer/renderer). That stays as-is. This plan is
about errors raised from the user's code embedded in templates.

## Context

`elp-template-error` (`0fb37a2`, `a55398c`) added `file:line:column`
tracking for engine-level failures via a checkpoints list mapping
body-string offsets back to `.elp` byte offsets. The same checkpoints
data is most of what's needed to teach SBCL's source-location tracking
about template positions — the bridge already exists, it just isn't
wired to the compiler's source-info plumbing. Once it is, swank reports
correct locations to any client (vlime, SLIME, sly) without further
work, since the protocol is editor-agnostic.

ELP is partly a vehicle for figuring out efficient Lisp workflows.
A `.elp` filetype that hands off to vlime is a concrete test of how
far the swank-per-worktree image setup carries when the file isn't
`.lisp`.

## Related plans

- `elp-nvim-filetype.md` — editor-side counterpart (GitHub issue #4):
  arglist / completion / eval-defun inside `<% %>` via vlime. Mostly
  independent; M-. on symbols *defined inside* a template only resolves
  to the right `.elp` line once this plan's per-form locations land,
  but the rest of the editor work doesn't depend on it.
- `reader-macro-codegen.md` — replaces the `read-from-string` pipeline
  with a reader-driven path. If it lands first, Layer 1 below probably
  dissolves into "set `*compile-file-pathname*` while reading"; if this
  plan lands first, the two designs need reconciling.
- `stream-input.md` — adds string/stream input. Same compile-path
  reconciliation concern as the reader-macro plan; "compile-string with
  a synthetic pathname" needs to agree with whatever Layer 1 settles
  on.

## Approach

Layered, error-locations-first. Each layer is independently useful;
stop whenever the remaining layers stop feeling worth it.

### Layer 1 — load templates as named compilation units (delivers the headline)

Replace (or add alongside) the current `read-from-string` path with
one that:

1. Writes the generated body to a temp `.lisp` file (or uses an
   in-memory stream paired with `*compile-file-pathname*`).
2. `compile-file`s it with `*compile-file-pathname*` set to the
   `.elp` source.
3. Loads the resulting fasl.

This alone makes runtime errors from template code report
`template.elp` as the source file in backtraces and the vlime
debugger, even before per-form line accuracy. This is the cheapest
move that delivers most of goal #1.

### Layer 2 — per-form source locations from checkpoints

Bridge the existing checkpoints (body-offset → `.elp` byte-offset)
into SBCL's source-location records so individual forms in the
generated code carry `.elp` line/column, not body-string positions.
This is what makes errors land on the *right line*, not just the
right file.

Options, in order of effort:

- **Custom read-with-locations**: replace `read-from-string` with a
  loop that reads forms one at a time, capturing `file-position`
  before each `read`, then maps each form to a `.elp` byte-offset
  via the existing checkpoints, then to line/column via
  `byte->line+column`.
- **Walk-and-tag**: after reading, walk the form tree and attach
  source-location plists via `sb-c::source-location` machinery.
  Requires the per-form positions from the previous bullet anyway.
- **Generate via `compile-file` with location declarations**: emit
  source-location forms directly into the generated `.lisp` so the
  compiler picks them up natively. Most idiomatic if it works;
  needs a spike to confirm SBCL accepts injected locations this
  way.

Riskiest piece — flag as a spike before committing to a design.

### Layer 3 — string-input compile path (cross-ref)

If `stream-input.md` lands and adds a string-rendering path, Layer 1
becomes "compile-string with a synthetic pathname" rather than
write-temp-file + `compile-file`. The two designs should be
reconciled rather than diverging.

## Cost note from #8 simplification (2026-04-26)

While shipping #8 (parameterized-compiled-template) we briefly added
a code walker (`sb-walker:walk-form`) to identify free template
variables, then removed it in commit `6db0910f` and replaced with
`progv` over the context-alist. Net deletion was ~200 LoC. The
walker wasn't actually load-bearing for #8's goal — `progv`
covers the compile-once / render-many use case in a few lines.

Direct relevance to this plan: **Layer 2's "Walk-and-tag" option
re-introduces a code walker of comparable weight.** Tagging
individual subforms with `.elp` source-locations means walking the
generated body tree and attaching `sb-c::source-location` records
(or equivalent) per form. That's the same machinery — and roughly
the same LoC cost — we just stripped out. Worth pricing in before
committing to Layer 2.

Layer 1 ("compile-file with `*compile-file-pathname*` set to the
`.elp`") doesn't need a walker. It gets you file-level location
accuracy across the whole compiled lambda — backtraces, debugger
"source" jumps, and swank's `find-source-location` all land on the
right `.elp` file, even if the line within the file is whatever the
compiler defaults to. For a lot of debugging that's already a big
step up; line accuracy is a nice-to-have on top.

The "Custom read-with-locations" sub-option of Layer 2 sidesteps
the walker by capturing positions during `read`, before any walking
is needed. That's probably the cheaper route if Layer 2 is wanted
— the checkpoints data already gives us most of it. Worth picking
that path explicitly over walk-and-tag unless something forces the
walker back.

Aside on warnings: with `progv` (no walker) and no `(declare
(special …))` for free vars, SBCL emits "undefined variable"
style-warnings at compile time for every free reference, regardless
of whether the alist actually binds it. The current
`compile-template` muffles these via `(handler-bind ((warning
#'muffle-warning)) (compile …))` because they're constant noise,
not signal — they fire identically on a working template and a
typo'd one. If a future pass declares specials (e.g. via the
walker), warnings become meaningful again and muffling should be
reconsidered.

Aside on swank/lisp-mcp: source-location tracking is useful for any
client that consumes the data, not only human editor integrations.
The `eval_swank` MCP transport surfaces conditions as text without
location info today; with Layer 1 in place, conditions raised from
template code would carry the `.elp` pathname and `swank:frame-
source-location` would resolve. That's a tangible improvement for
agentic Lisp work on `.elp` files, not just nvim/vlime usage.

## Open questions

- Does SBCL preserve injected source-locations through
  `compile-file` → `load` for use by swank's `find-source-location`,
  or only during the compile itself? (Affects whether Layer 2
  helps M-. on template-defined functions, or only error reports.)

## Non-goals

- LSP-protocol implementation. Rides on swank, not LSP.
- Editor-side region handling (filetype plugin, tree-sitter
  injection, vlime keymap activation inside `<% %>`). Tracked in
  `elp-nvim-filetype.md` / issue #4.
- Templating-DSL-aware features (e.g. completing context-alist
  keys); out of scope until the basics work.
