# Split `translated-template` into sexp-template + lambda-template

## Goal

Replace the single `translated-template` class with two composed layers:

- **`sexp-template`** — translated body as a string, source-specific
  wrapper applied, position-map, free-vars, source-name. Evaluable
  on its own given free-var bindings; the analysis/LSP surface.
- **`lambda-template`** — composes a sexp-template, adds the
  callable `(lambda (stream &key …))` wrapper with supplied-p
  discipline. The render surface.

A small protocol class lets both implement a shared interface
(`template-text`, `template-form`, position-map generics).

## Why

- **LSP/go-to-def wants the bare body.** The lambda's `&key` params
  shadow project-specific scope (e.g. `for-service` bindings),
  sending go-to-def to a synthesized keyword arg instead of the
  user's macro.
- **Today's class conflates two jobs** — syntax→Lisp translation
  and callable-wrapping — only because free-var discovery sits
  between them. Splitting puts each job on its own layer.
- **READ failures during edits shouldn't destroy the whole object.**
  With the split, a sexp-template can exist even when free-var
  discovery fails — LSP keeps text + position-map.
- **Composition over inheritance.** Lambda-template *wraps* a
  sexp-template; it isn't a *kind of* one. HAS-A matches data flow
  and keeps the protocol open to future variants.

## Sequencing

1. **Fix latent handler-bind bug first.** Today's error handler
   references `elp::source`, which only mmap-source binds — string-
   source templates crash the handler. Make string-source's
   `source-wrap-lambda-body` non-identity so `elp::source` is always
   bound. Standalone, lands first because step 2 depends on the
   wrapper being uniform across backends.

2. **Extract `sexp-template`.** Eagerly drain the stream in its
   constructor; own text, position-map, source-name, free-vars;
   apply the source wrapper and the handler-bind. Stream class
   becomes a private implementation detail of the constructor.

3. **Reframe `translated-template` → `lambda-template`** as
   composition over a sexp-template slot. Position-map queries
   delegate to the inner sexp-template plus the prefix shift.

4. **Protocol class + shared generics.** `template-text`,
   `template-form`, and the doc↔source generics live on the
   protocol class. Lambda-template-only operations
   (compile-to-callable) stay on lambda-template.

5. **Docs.** Update README.md, package docstrings, and any internal
   comments that reference the old single-class design.

## Commits

Ordered. Each leaves the tree green (`make test` passes) and is a
single reviewable diff.

1. **Make `source-wrap-lambda-body` bind `elp::source` uniformly.**
   Today only mmap-source binds it; string-source's identity wrapper
   leaves the handler-bind's `elp::source` reference unbound, so a
   string-source template raising mid-render crashes the handler
   itself. Give string-source a non-identity wrapper that binds
   `elp::source` to a fresh `string-source` instance.
   *Verify:* add a test that renders a string-source template
   raising a runtime error and asserts the condition is
   `elp-template-error` with the supplied display name (not the raw
   unbound-variable crash). Existing tests stay green.

2. **Extract `sexp-template` class.** New class owning text,
   position-map, source-name, free-vars. Constructor eagerly drains
   a `template-body-stream`, applies `source-wrap-lambda-body`, and
   wraps the handler-bind inside that. Stream class becomes a
   private detail of the constructor. `translated-template` keeps
   working — for this commit it consumes a `sexp-template`
   internally instead of driving the stream directly, but its
   external contract is unchanged.
   *Verify:* `make test` green. Add tests that directly construct a
   `sexp-template`, READ its text, and confirm free-vars and
   position-map match what `translated-template` produced on the
   same source.

3. **Rename `translated-template` → `lambda-template`; switch to
   composition.** Holds a `sexp-template` slot; constructor builds
   the inner sexp-template, then wraps with the callable lambda
   signature + supplied-p checks. Position-map queries delegate to
   the inner sexp-template with prefix-length offset. Old name kept
   as a deprecated alias for one cycle so external callers don't
   break in this commit.
   *Verify:* `make test` green; rendered output of existing fixtures
   byte-identical; `translated-template-text` still works via alias.

4. **Protocol class + shared generics.** Introduce a small protocol
   class both implement. `template-text`, `template-form`, and the
   doc↔source generics live there. Compile-to-callable stays
   lambda-template-only. Update exports; retire the deprecated
   `translated-template` alias.
   *Verify:* `make test` green. Add tests that exercise the
   protocol generics polymorphically across both classes.

5. **Docs.** README.md, package docstrings, internal comments
   referencing the old single-class design. No code changes.
   *Verify:* spot-read rendered docs; `make test` green.
