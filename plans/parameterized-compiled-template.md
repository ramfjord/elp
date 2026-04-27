# Parameterized compiled-template value

## Goal

Expose `elp:compile-template` as the public entry point that returns
a `compiled-template` — a funcallable-instance value carrying source
metadata. Calling it with a context-alist (and optional stream)
renders. Today's pathname `render` becomes a thin wrapper: compile
+ funcall. The context-alist stops being baked into the generated
form as literals, so the same compiled value can be reused across
calls with different contexts.

By the end of this branch:

- `(elp:compile-template #p"page.elp")` returns a
  `compiled-template` instance.
- That instance is `funcall`-able: `(funcall tmpl ctx)` and
  `(funcall tmpl ctx stream)` both work.
- `(elp:render tmpl ctx)` and `(elp:render tmpl ctx stream)` work
  via a method specialized on `compiled-template`.
- The existing pathname `render` method delegates to
  `compile-template`, no behavior change for current callers.
- `compile-template` and `compiled-template` are exported from the
  `elp` package.

Tracked as GitHub issue #8.

## Context

`build-render-form` (`elp.lisp:260`) currently quotes context values
into the generated form as literals (`elp.lisp:278`):

```lisp
(let ((bindings (mapcar (lambda (b) `(,(car b) ',(cdr b))) context-alist)))
  (if bindings `(let ,bindings ,body) body))
```

So the generated lambda is "render-this-template-with-this-exact-data."
Re-rendering with new data means re-parsing and re-generating from
scratch — there's no way to compile once and call many times. The
fix is small in scope (decouple compilation from binding) but the
right shape for it has implications for issues #3, #5, and #10:

- **#3** (string input) wants to add another input adapter; better
  to add it once `compile-template` is the layer-where-input-becomes-
  template-value, instead of threading a string path through the
  pathname-shaped `render`.
- **#5** (source locations) wants somewhere to hang `source-pathname`
  metadata — the funcallable-instance's slot is exactly that.
- **#10** (benchmarks) wants to measure compile-once-render-many,
  which today is literally not separable.

So this plan should ideally land before those three.

## Related plans

- `swank-elp-source-locations.md` (issue #5) — the `source-pathname`
  slot defined here is the natural attachment point for that plan's
  Layer 1/2 work. Coordination helps but neither blocks the other.
- `stream-input.md` (issue #3) — should target `compile-template`
  as its public primitive (`(compile-template-string string)` or a
  `compile-template` method on string), not the pathname `render`
  flow. Soft sequencing: this plan first.
- `reader-macro-codegen.md` — already reader-driven per its plan;
  this plan touches `build-render-form`'s *output* side (how the
  body is wrapped), which sits below reader-macro-codegen's scope.
  If both are in flight, sequence reader-macro-codegen first since
  it changes more of `build-render-form`. If this plan lands first,
  reader-macro-codegen's body-emission still composes with the new
  wrapper.
- `mmap-tokenize.md` — orthogonal in concept, touches the same hot
  area. Flag for merge ordering only.
- `trim-mode.md`, `elp-nvim-filetype.md`, `reader-aware-close-delim.md` —
  orthogonal.

## Design notes

### Variable lookup strategy

Today's LET binds context symbols *lexically* with the values baked
in at compile time. The parameterized form needs those same symbols
to resolve at funcall time, against an alist that can change per
call. Three plausible designs:

- **A. Walk body for free vars, emit `(let ((sym (cdr (assoc 'sym
  ctx)))) ...)` per referenced symbol.** Preserves today's lexical
  ergonomics. Surfaces unknown context keys as either compile-time
  errors (if we require the alist to declare its keys at
  compile-template time) or as `nil` at runtime (if we accept any
  alist and bindings default to `nil`).
- **B. `progv` over the alist at funcall time.** Bind every symbol
  in the alist as a special variable for the dynamic extent of the
  render. No walking. Symbols become special bindings, not lexical;
  SBCL will likely warn about undefined variables at compile time
  unless declared special. Walking is still needed for the special
  declarations, which gives back most of A's complexity.
- **C. Symbol-macrolet over keys, accessor function lookup.**
  Template code references `name`; symbol-macro expands to `(elp::ctx
  name)` which does runtime alist lookup. Needs walking too, plus
  introduces an accessor.

Lead candidate: **A**. Closest to today's behavior, no surprises
about variable scope, errors point at the right place when keys are
missing. Walker can be a focused free-variable collector — doesn't
need to be a full code walker, just "find symbols in non-binding
position." Use `sb-walker:walk-form` if hand-rolling proves
fragile.

This is the main design uncertainty in the plan; commit 4's
`Decisions:` block (appended by `do-plan`) will record what landed.

### Funcallable-instance shape

```lisp
(defclass compiled-template ()
  ((source-pathname :initarg :source-pathname
                    :reader compiled-template-source-pathname
                    :initform nil)
   (compiled-at     :initarg :compiled-at
                    :reader compiled-template-compiled-at
                    :initform (get-universal-time)))
  (:metaclass sb-mop:funcallable-standard-class))
```

`compile-template` builds the lambda, calls `(compile nil
lambda-form)`, instantiates the class, and uses
`sb-mop:set-funcallable-instance-function` to install the compiled
function. `print-object` shows
`#<COMPILED-TEMPLATE "page.elp">`.

### Where `template-code` goes

`template-code` (elp.lisp:187) currently returns the
context-baked form. After this plan it should return the new
parameterized lambda form (a `(lambda (ctx &optional stream)
...)`), so it remains a useful debugging tool and stays consistent
with what `compile-template` actually compiles. The public surface
of `template-code` doesn't otherwise change.

## Commits

1. ✅ **Refactor `build-render-form` to separate body construction
   from context wrapping.** Extract `build-template-body` returning
   the inner `(progn ,@forms)` only; existing `build-render-form`
   keeps the LET-of-literals wrapping for now. Pure refactor — no
   behavior change.
   *Verify:* full FiveAM suite passes (`make test`); diff of
   `template-code` output for a fixture template is byte-identical
   before and after.

2. ✅ **Add a free-variable collector for template body sexps.** New
   internal helper `template-free-vars` (or similar) that walks a
   body form and returns the set of symbols referenced free,
   ignoring `let`/`let*`/`lambda`/`flet`/`labels`/`symbol-macrolet`
   binding positions. Lead implementation: `sb-walker:walk-form`
   with a hook that records free vars; fall back to a hand-rolled
   walker only if `sb-walker` proves problematic in the SBCL
   version we target.
   *Verify:* unit tests on hand-built sexps covering plain
   references, shadowing inside `let`, lambda parameters, and
   nested binding constructs.
   **Decisions:**
   - `sb-walker:walk-form` worked first try; no hand-rolled fallback
     needed.
   - Filter scope: `:eval` context only, plus exclude symbols whose
     package is `:elp` (codegen artifacts: `*template-ptr*`,
     `*current-template-span*`, `write-output-range`), `:common-lisp`
     (builtins), or `:keyword`. Function-position symbols are
     naturally excluded since the walker labels them `:function`,
     not `:eval` — matches today's semantics where templates pass
     data in value position, not function position.

3. ✅ **Add `compiled-template` funcallable-instance class.** Class
   definition with `source-pathname` and `compiled-at` slots;
   readers; `print-object` method. Not yet wired to anything.
   *Verify:* `(make-instance 'compiled-template :source-pathname
   #p"x.elp")` constructs; `(format t "~A" tmpl)` prints
   `#<COMPILED-TEMPLATE "x.elp">`; instance is `functionp` after
   `sb-mop:set-funcallable-instance-function` installs a stub.

4. ✅ **Implement `compile-template` (pathname method).** Build the
   parameterized lambda using `build-template-body` + the
   free-variable walker (per Design notes A); compile it;
   instantiate `compiled-template` and install the compiled
   function. Internal-only at this point — not yet exported, no
   `render` integration.
   *Verify:* new tests that compile a representative template
   once, then funcall the result twice with different contexts and
   assert each output. Cover at least: literal-only, single
   `<%= var %>`, `<% (when …) %>` block spanning multiple tags,
   missing context key behavior (whatever A lands on — record in
   plan via `do-plan` decisions).
   **Decisions:**
   - Missing-context-key behavior: silent NIL via `(cdr (assoc 'sym
     ctx))`. Trades today's "unbound variable error" for
     "renders NIL"; favored simplicity over strictness. Easy to
     tighten later by switching the binding form to a lookup that
     errors when ASSOC returns NIL.
   - Per-call mmap retained: the lambda re-mmaps PATHNAME on every
     funcall (unchanged from today's `template-code` shape). The win
     here is parameterization, not avoiding the mmap. Caching the
     mmap across calls has lifecycle issues (file mtime, GC) that
     belong to a future cache plan, not this one.
   - Stream parameter defaulted in the lambda's lambda-list
     (`&optional (stream *standard-output*)`), so both `(funcall
     tmpl ctx)` and `(funcall tmpl ctx stream)` work.
   - Empty-file shortcut: detected before mmap (mmap with size 0
     would fail) and fulfilled with a stub lambda returning
     `(values)` — preserves today's `template-code` empty-file
     behavior while still returning a valid `compiled-template`
     instance.
   - Package matching of free-var symbols vs. context-alist keys
     is the caller's responsibility. The walker uses the symbols as
     read from the template (under whatever `*package*` was in
     effect at compile time); context-alist keys must match. This
     matches today's `build-render-form` semantics — not a new
     constraint, but worth flagging.

5. ✅ **Add `render` method on `compiled-template`; reimplement
   pathname `render` via `compile-template`.** New
   `defmethod render ((tmpl compiled-template) ctx &optional
   stream)`; the pathname method becomes
   `(render (compile-template path) ctx stream)`. Universal entry
   point preserved.
   *Verify:* full FiveAM suite passes unchanged; manual smoke of
   `(elp:render #p"…" '((…))) ` matches pre-refactor output for a
   couple of fixture templates.
   **Decisions:**
   - One observable behavior change: `<%= undefined-var %>` (a
     template var with no matching context-alist key) now renders
     `NIL` silently instead of raising `elp-template-error`. This
     is the design A "missing key → NIL" branch from the plan's
     Design notes. It surfaced when commit 5 routed pathname
     `render` through the new path; the two existing typo-detection
     tests (`runtime-error-undefined-variable` and
     `runtime-error-column-with-leading-whitespace`) were updated to
     a single `undefined-variable-renders-as-nil` test.
   - Considered a stricter "error on missing key" via
     `symbol-macrolet` expanding to a runtime check, but it broke
     `simple-code-block-rendering` (`<% (setf x 42) %>...`) because
     `setf` of a `let`-form is not a place. The let-bind form
     supports both `setf` and the silent-NIL semantics, so it won.
   - Stricter modes can be added later as opt-in (e.g. a keyword
     to `compile-template`) without re-doing the structural work.

6. ✅ **Export `compile-template` + `compiled-template`; update
   `template-code`; document in README.** Add the symbols to the
   `elp` package's `:export` list. Update `template-code` to emit
   the new parameterized form (keeping its docstring accurate).
   Add a short README section under "Usage" titled "Compile once,
   render many" with a concrete example. Reference issue #8 for
   the design rationale.
   *Verify:* `(use-package :elp) (elp:compile-template …)` works
   from a fresh REPL with no internal-symbol references; README
   example block is copy-paste-runnable.
   **Decisions:**
   - Exported symbols: `compile-template`, `compiled-template`,
     `compiled-template-source-pathname`,
     `compiled-template-compiled-at` (the metadata readers — handy
     for callers that introspect a cache, log compile times, etc.).
   - Removed `build-render-form` and `wrap-render-form` as dead
     code — both were the literal-bake variant superseded by
     `build-template-body` + `build-compile-template-form`. The
     existing `build-render-form-shape` test was rewritten as
     `build-template-body-shape`, pinning the body-only sexp; the
     wrapper shape is implicitly covered by the `compile-template`
     behavior tests.
   - `template-code` now emits the parameterized lambda form (the
     same one `compile-template` compiles). The optional
     `context-alist` parameter is retained for back-compat but
     ignored — kept out of a breaking-signature change since the
     non-goals call `template-code` "stays as a debug-introspection
     helper". Worth flagging: callers that previously relied on
     `(eval (template-code …))` returning rendered output now get
     a function back and must funcall it. CLI's `--print` flag
     still works (it prin1's the form, doesn't eval).

## Future plans

- Cache invalidation / mtime-aware compile cache. Out of scope
  here; deliberately deferred per #8's "out of scope" section.
- String-input `compile-template` method (issue #3, plan
  `stream-input.md`).
- Hooking `source-pathname` into source-location reporting
  (issue #5, plan `swank-elp-source-locations.md`).

## Non-goals

- Global per-image cache or any cache-key bikeshedding.
- File watching / auto-recompilation.
- Removing `template-code`. It stays as a debug-introspection
  helper, just emitting the new shape.
- Changing `render`'s public signature (still
  `(input ctx &optional stream)`).
