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

1. ✅ **Make `source-wrap-lambda-body` bind `elp::source` uniformly.**
   Today only mmap-source binds it; string-source's identity wrapper
   leaves the handler-bind's `elp::source` reference unbound, so a
   string-source template raising mid-render crashes the handler
   itself. Give string-source a non-identity wrapper that binds
   `elp::source` to a fresh `string-source` instance.
   *Verify:* add a test that renders a string-source template
   raising a runtime error and asserts the condition is
   `elp-template-error` with the supplied display name (not the raw
   unbound-variable crash). Existing tests stay green.

2. ✅ **Extract `sexp-template` class.** New class owning text,
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
   **Decisions:**
   - **`*print-circle*` must be NIL for sexp-template's PRIN1.** Each
     layer PRIN1s separately, then their texts are concatenated. With
     `*print-circle* T` the two outputs assign overlapping `#N=`
     labels and the concatenated text fails to READ
     ("multiply-defined label"). Lambda-template still needs
     `*print-circle* T` to share supplied-p gensym labels across its
     `&key` declaration and `unless` checks.
   - **Two handler-binds instead of cross-layer splicing.**
     Sexp-template owns the runtime-error handler-bind (needs
     `elp::source` from source-wrap). Lambda-template adds its own
     `(handler-bind ((unbound-variable …)))` outside sexp-template
     to translate supplied-p check failures. Keeps the layer
     boundary clean — no marker-splicing to insert lambda-template
     prelude inside sexp-template's body.
   - **Doc↔source methods on sexp-template duplicate the
     translated-template body** — both will collapse onto a protocol
     class in commit 4.

3. ✅ **Rename `translated-template` → `lambda-template`; switch to
   composition.** Holds a `sexp-template` slot; constructor builds
   the inner sexp-template, then wraps with the callable lambda
   signature + supplied-p checks. Position-map queries delegate to
   the inner sexp-template with prefix-length offset. Old name kept
   as a deprecated alias for one cycle so external callers don't
   break in this commit.
   *Verify:* `make test` green; rendered output of existing fixtures
   byte-identical; `translated-template-text` still works via alias.
   **Decisions:**
   - **Composition was already done in commit 2** — the `sexp-template`
     extraction inherently turned `translated-template`'s constructor
     into a composition wrapper. This commit just renames the class.
   - **Position-map is pre-shifted at construction, not queried
     through delegation.** Cheaper at query time and matches the
     pre-rename behavior. Operationally equivalent to delegating to
     the inner sexp-template + adding the prefix offset per query.
   - **Aliases use `(setf (find-class …))` + `(setf (fdefinition …))`
     rather than a subclass or deftype** — gives full transparency
     for `make-instance`, `typep`, accessor calls, all in one form.
   - **Entry function `translate-template` was *not* renamed.** Its
     return-type name changed, but the function name is fine —
     consumer code reads naturally as "translate a template", not
     tied to the return class's name.

4. ✅ **Protocol class + shared generics.** Introduce a small protocol
   class both implement. `template-text`, `template-form`, and the
   doc↔source generics live there. Compile-to-callable stays
   lambda-template-only. Update exports; retire the deprecated
   `translated-template` alias.
   *Verify:* `make test` green. Add tests that exercise the
   protocol generics polymorphically across both classes.
   **Decisions:**
   - **Protocol class uses shared slots, not pure abstract methods.**
     `template` owns `text`, `position-map`, `source-name`;
     subclasses re-list slot names just to add their own
     class-specific readers (`sexp-template-text` etc.) — CLOS
     slot inheritance merges the definitions onto one slot.
     Constructors keep using `(setf (slot-value s 'text) …)` and
     it Just Works.
   - **The deprecated `translated-template` alias was retired in
     this commit, not held for a cycle.** A grep across the
     mediaserver checkout showed zero downstream uses of the old
     names, so there was nothing to migrate away from.
   - **Test helper `template-form` had to be deleted.** It shadowed
     the new `elp:template-form` GF via the test package's
     `:use :elp`, redefining the fdefinition on the imported symbol
     so all calls (including `elp:template-form`) hit the
     test-local function that called `lambda-template-text`
     directly. Replaced helper calls with `elp:template-form`.

5. **Docs.** README.md, package docstrings, internal comments
   referencing the old single-class design. No code changes.
   *Verify:* spot-read rendered docs; `make test` green.
