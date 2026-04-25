# Swank-aware `.elp` editing with source locations

## Goal

Two outcomes, the first is the headline:

1. **Errors point to the right `.elp` line.** Compile-time warnings and
   runtime errors raised from code *inside* template tokens carry source
   locations that resolve to the originating `.elp` file and line/column
   — so vlime's debugger ("source" / `\sl` jump-to-source), backtraces,
   and compiler notes all land in the template, not in a synthetic
   `read-from-string` buffer with no useful position.

2. **Editing `.elp` feels like editing Lisp inside `<% ... %>`** — vlime
   commands (arglist, M-., completion, eval-defun) work on symbols
   in expression and code regions, against the running worktree image.

Complementary to `elp-template-error`, which already handles failures in
the *engine* layer (tokenizer/renderer). That stays as-is. This plan is
about errors and tooling for the user's code embedded in templates.

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

None — checked `./plans/` on 2026-04-25 and the directory was empty
(this is the first plan).

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

### Layer 3 — nvim `.elp` filetype with vlime integration (goal #2)

`ftdetect/elp.vim` + `ftplugin/elp.vim` (or under
`after/ftplugin/elp.vim`) that:

- Sets up syntax highlighting for `<% %>` / `<%= %>` / `<%# %>`
  delimiters and treats their interiors as embedded Lisp (vim's
  `:syntax include` against `lisp.vim`).
- Inside expression/code regions, makes vlime's keymaps active so
  arglist, M-.-equivalent (`\j` / `<Plug>(vlime-goto-source)`), and
  completion query the running image at point.
- Outside those regions, treats the buffer as plain text.

Limitation without Layer 2: M-. on a symbol *defined by the template
itself* (e.g. a `defun` inside `<% %>`) jumps to wherever the
generated form was last compiled — unhelpful unless source
locations are tagged. So Layer 3 is most useful *after* Layer 2,
though basic arglist/completion works against the image with just
Layer 1 in place.

Open question: how `mmm-mode`-style region handling is best done in
nvim. `:syntax include` covers highlighting; making vlime's
buffer-local commands respect regions (rather than the whole buffer)
is the part to investigate. Tree-sitter with an injection grammar
might be cleaner than vim regex syntax for region detection.

### Layer 4 — string-based render path (cross-ref)

Tracked separately in `TODOs.md`, but worth noting here: if Layer 1
moves to `compile-file`, the string-rendering TODO becomes
"compile-string with a synthetic pathname" and the two designs
should be reconciled rather than diverging.

## Open questions

- Does SBCL preserve injected source-locations through
  `compile-file` → `load` for use by swank's `find-source-location`,
  or only during the compile itself? (Affects whether Layer 2
  helps M-. on template-defined functions, or only error reports.)
- Is there a vlime extension hook for region-scoped commands, or
  does region handling need to live in the filetype plugin?
- Tree-sitter `.elp` grammar with a Lisp injection vs. hand-rolled
  vim syntax — which lands faster and is less fragile? (Tree-sitter
  also gives nvim's `nvim-treesitter` injections for free.)

## Non-goals

- LSP-protocol implementation. Rides on swank, not LSP.
- Editor support outside nvim (vlime/nvlime). SLIME/sly users get
  the error-location wins for free via Layer 1+2 since those are
  swank-protocol-level; editor-side niceties (Layer 3) are
  nvim-only here.
- Templating-DSL-aware features (e.g. completing context-alist
  keys); out of scope until the basics work.
