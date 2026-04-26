# nvim `.elp` filetype with vlime inside `<% %>`

## Goal

Editing a `.elp` file in nvim feels like editing Lisp inside the
`<% ... %>` / `<%= ... %>` / `<%# ... %>` regions and like editing
plain text outside them. With cursor inside a Lisp region, vlime's
arglist, completion, eval-defun, and goto-source commands query the
running per-worktree swank image and Just Work. Outside those
regions the buffer behaves as text/HTML.

Tracked as GitHub issue #4 (the editor-side half of the original
"swank integration" framing).

## Context

ELP is partly a vehicle for figuring out efficient Lisp workflows.
A `.elp` filetype that hands off to vlime is a concrete test of how
far the swank-per-worktree image setup carries when the file isn't
`.lisp` — and is also the only piece that makes day-to-day template
authoring feel native.

This is purely editor-side work; nothing in the engine needs to
change for the basics. A custom swank op is a possible escape hatch
if vim/vlime turn out to be hostile to region-scoped commands, but
the expected design is the standard "embedded mode" pattern:
recognize template syntax in the buffer, switch the active
syntax/keymaps to lisp inside `<% %>`, and let unmodified vlime do
the rest.

## Related plans

- `swank-elp-source-locations.md` — covers the engine-side error /
  source-location work (GitHub issue #5). Layer 3 of *that* plan is
  this work; once this plan exists, Layer 3 there should be removed
  to avoid duplication. Soft sequencing: M-. on a symbol *defined
  inside* a template only resolves to the right `.elp` line once
  source-locations land, but arglist / completion / eval-defun on
  symbols defined elsewhere work against the image with no
  source-location support at all — so this plan is independently
  useful and not blocked.
- `reader-macro-codegen.md` — changes how template bodies become
  forms, but does not affect editor-side region handling.

## Mechanism overview

Two layers, increasing scope:

1. **Recognize regions.** A tree-sitter grammar with a Lisp injection
   is the cleanest path on modern nvim — `nvim-treesitter` then
   gives highlighting, text objects, and `:InspectTree` for free,
   and the injection mechanism is the standard answer to "this
   range is actually language X." Hand-rolled vim regex syntax with
   `:syntax include @lisp lisp.vim` is the fallback if the grammar
   is more friction than it's worth for an experiment.
2. **Region-scoped vlime.** vlime's commands operate on the form at
   point. Inside an injected Lisp region they should already see
   the right form via tree-sitter; the open question is whether
   vlime's "form at point" reader respects injection boundaries or
   greedily consumes template delimiters. If the latter, an
   `ftplugin/elp.vim` helper can either narrow the buffer for the
   command's duration or pre-extract the form text and call vlime's
   eval/arglist functions directly.

If neither works cleanly, the escape hatch is a custom swank op:
the editor sends the whole buffer + cursor offset, the op parses
the template server-side and answers. Heavier, last resort.

## Commits

1. **`ftdetect/elp.vim` + skeleton `ftplugin/elp.vim`** — register
   `*.elp` as filetype `elp`, set sensible defaults
   (`commentstring` for `<%# %>`, basic `iskeyword`). No syntax or
   vlime wiring yet.
   *Verify:* open a `.elp` file in nvim, `:set ft?` reports `elp`,
   `gcc` (or equivalent commenting plugin) produces `<%# … %>`.
2. **Tree-sitter grammar for `.elp`** — minimal grammar covering
   the three tag flavors (`<%`, `<%=`, `<%#`), their close-delims
   (including trim variants `-%>`), and plain-text spans between
   them. Published locally; nvim wiring via `nvim-treesitter`'s
   `parser_install_dir` or as a vendored parser.
   *Verify:* `:InspectTree` on a sample `.elp` file shows correct
   tag/text nodes; trim-flag tokens (`<%-`, `-%>`) parse as such.
3. **Lisp injection** — add a tree-sitter `injections.scm` mapping
   the interior of `<% %>` and `<%= %>` regions to `lisp`. Plain
   text and `<%# %>` (comment) regions get no injection.
   *Verify:* with cursor inside `<% (foo |) %>`, `:Inspect`
   reports the highlight chain reaching `lisp` captures; Lisp
   syntax highlighting is visible inside tags only.
4. **vlime keymap activation inside Lisp regions** — `ftplugin`
   hook that enables vlime's buffer-local keymaps and ensures its
   "form at point" works inside `<% %>`. Probe vlime's behavior;
   if needed, wrap the relevant commands to narrow / extract before
   delegating.
   *Verify:* with a swank image attached, cursor inside a `<% %>`
   region: arglist popup for a known function, completion, and
   `\e` (eval-defun) on a `(defun ...)` inside the region all
   succeed. Same commands outside the region are no-ops or fall
   through gracefully.
5. **README section** — short "Editing `.elp` files in nvim"
   subsection covering install steps (filetype plugin path, tree-
   sitter parser registration, vlime prerequisite) and the known
   limitation that M-. on a template-defined symbol resolves
   accurately only after the engine-side source-locations work
   (#5) lands.
   *Verify:* steps work from a clean nvim config in a fresh
   worktree.

## Open questions

- Does vlime's "form at point" reader respect tree-sitter injection
  boundaries, or does it scan raw buffer characters? (Determines
  whether commit 4 is trivial or needs wrapper functions.)
- Tree-sitter grammar maintenance cost for a one-person experiment
  — is the cleaner UX worth it vs. `:syntax include`? Reassess
  after commit 2 if the grammar feels like a tarpit.
- Comment regions (`<%# %>`): worth a separate `comment` injection
  for spell-check / TODO-highlighting, or leave as plain text?

## Future plans

- Custom swank op as a fallback path, if region-scoped commands
  prove unworkable from vim's side.
- Editor support beyond nvim (Emacs/SLIME, sly, VS Code) — same
  pattern, different host. Not on the near-term roadmap.

## Non-goals

- Templating-DSL-aware completion (e.g. completing context-alist
  keys). Scope is "Lisp inside the tags works"; template-aware
  smarts are a later, separate concern.
- LSP. Rides on swank.
- Engine changes. If this plan needs an engine change, that's a
  signal to fold the change into `swank-elp-source-locations.md`
  instead.
