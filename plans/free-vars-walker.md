# Free-vars walker for compiled forms

**Status: shipped (single commit on main).** Single-commit landing
covered all of commits 1–5 below; the deltas described under each
commit are what's in main now. A few unplanned course-corrections
landed alongside; see the **Decisions** section below.

## Goal

A standalone helper that takes an arbitrary Lisp body sexp and
returns:

- the set of **free variable references** in that body, accounting
  for lexical bindings introduced by the form itself (`let`,
  `let*`, `lambda`, `flet`, `labels`, `symbol-macrolet`, etc.), and
- a **compiled function** that can be invoked with values for those
  free variables.

Both pieces are bundled into a single value (a `compiled-form`
struct). ELP's template pipeline becomes one caller of this
primitive; the primitive itself is generic over any sexp.

By the end of this branch:

```lisp
(let ((cf (elp:compile-form '(when ready (format t "~A" name)))))
  (elp:compiled-form-free-vars cf)        ; => (READY NAME)
  (funcall (elp:compiled-form-fn cf)
           '((ready . t) (name . "Ada"))) ; => prints "Ada"
  )
```

## Motivation

The post-plan simplification on `parameterized-compiled-template.md`
dropped the walker because nothing inside ELP itself needed it —
`progv` covers runtime binding without walking. That calculus
changes when a **caller** of ELP wants to enumerate the variables a
template references *before* rendering, e.g. to validate a context
alist, prompt the user for missing values, or surface "this
template needs X, Y, Z" upstream.

Reframed at the right level, this is not a template feature. It is
a sexp primitive: given a body, what does it depend on, and how do
I run it. ELP can call it from `compile-template`; other Lisp code
in this user's projects can call it directly.

## The walker is not ours to write

Initial drafts of this plan budgeted commits for choosing between
`sb-walker` and `agnostic-lizard`, then implementing a free-vars
collector on top of one of them. Spiking `hu.dwim.walker` against
the planned fixtures showed that work is unnecessary — the library
already classifies references and exposes the answer:

```lisp
(defun fv (form)
  (let* ((ast (hu.dwim.walker:walk-form form))
         (refs (hu.dwim.walker:collect-variable-references ast)))
    (remove-duplicates
     (mapcar #'hu.dwim.walker:name-of
             (remove-if-not
              (lambda (r) (typep r 'hu.dwim.walker:free-variable-reference-form))
              refs)))))
```

Verified correct on every fixture the plan would have tested by
hand, plus the harder ones:

| Form | Free vars |
|---|---|
| `(let ((x 1)) (+ x y))` | `(Y)` |
| `(let* ((x 1) (y x)) (+ x y z))` | `(Z)` |
| `(flet ((f (x) (+ x y))) (f z))` | `(Y Z)` |
| `(let ((x 1)) (let ((x 2)) x))` | `()` |
| `(loop for x in xs collect (+ x y))` | `(XS Y)` |
| `(destructuring-bind (a . b) pair (list a b c))` | `(PAIR C)` |
| `(multiple-value-bind (q r) (floor a b) (+ q r s))` | `(B A S)` |
| `(symbol-macrolet ((x (slot-of obj))) (+ x y))` | `(Y OBJ)` |
| `` `(foo ,x ,@ys) `` | `(YS X)` |

The library's *own* classification subsumes every filter rule the
prior `sb-walker`-based pass added by hand:

- Function-position symbols are not classified as variable refs at
  all (`format`, `+`, user-defined functions all absent).
- Keywords are not classified as variable refs (`:name` absent).
- `T`, `NIL`, numbers, strings — self-evaluating, not classified.
- Globally-proclaimed specials get their own class
  (`special-variable-reference-form`), not `free-variable-reference-form`.
  Confirmed: `(elp::write-output-range elp::*template-ptr* 0 100)`
  returns `()` because `*template-ptr*` is `defvar`'d.
- Quoted forms are not walked into.
- Macros (`when`, `loop`, `dolist`, etc.) expand transparently.

We do not need package-based filtering, do not need a `:eval`
context check, do not need to recognize binding forms. Those
problems are solved upstream.

### Dependency footprint

`hu.dwim.walker` pulls in the `hu.dwim` ecosystem
(`hu.dwim.def`, `hu.dwim.common`, etc.) — heavier than
`agnostic-lizard`, which is more or less a single file. Trade-off:

- **`hu.dwim.walker`**: 5-line wrapper, one Quicklisp dep entry, no
  walker logic in our code.
- **`agnostic-lizard`**: leaner deps, but we'd hand-roll a visitor
  that classifies refs as bound/free against a shadowed environment
  — back to writing scope tracking for every binding form we care
  about. That work is exactly what the post-plan simplification
  said wasn't worth it.

Lead candidate: **`hu.dwim.walker`**. ELP already depends on
`cffi`, `cl-ppcre`, and `alexandria`; the dep cost is real but
small relative to the alternative of owning walker logic.

## Design

### API surface

```lisp
(elp:compile-form sexp)                      ; => compiled-form
(elp:compiled-form-fn        compiled-form)  ; => function
(elp:compiled-form-free-vars compiled-form)  ; => list of symbols
(elp:compiled-form-source    compiled-form)  ; => the original sexp (for debugging)
```

Implementation shape: a plain `defstruct compiled-form (fn free-vars source)`.
The struct itself is not funcallable — callers use
`(funcall (compiled-form-fn cf) ...)`. The funcallable-instance
dance was removed in 2c93c8d for being more cost than its API
ergonomics returned; that judgment still holds.

The compiled function takes a single context-alist argument and
binds the free variables via `progv` for the call's extent — same
shape ELP's current `compile-template` uses. Free vars not present
in the alist signal an unbound-variable error at the reference
site, preserving the loud-failure-on-typo property simplification
restored.

### Out of scope

- Caching, memoization, mtime tracking.
- Reclassifying special variables as "free" — we surface only
  symbols the walker classifies as `free-variable-reference-form`.
  Callers decide what to do with anything else.
- Macro expansion control. We trust the walker's defaults.
- Re-introducing `compiled-template` metadata (`source-pathname`,
  `compiled-at`). Issue #5's territory.

## Commits

1. **Add `hu.dwim.walker` dependency.** Update `elp.asd` and
   confirm `(asdf:load-system :elp)` still works in a fresh image.
   No code changes yet.
   *Verify:* full FiveAM suite (81 tests) passes unchanged.

2. **Add `compile-form-free-vars` helper.** Five-line wrapper as
   above; internal symbol. Pinning tests on a representative
   fixture set: plain ref, `let` shadowing, `let*`, `lambda`,
   `flet`, `dolist`, `loop`, `multiple-value-bind`,
   `destructuring-bind`, `symbol-macrolet`, quoted forms,
   function-position-only, keyword args, ELP-internal specials,
   shadowing nested. These are pinning tests on the integration —
   walker correctness is `hu.dwim.walker`'s job — but they catch
   library-version regressions and document our expected behavior.

3. **Add `compiled-form` struct and `compile-form` constructor.**
   Defstruct, constructor that calls `compile-form-free-vars`,
   builds a `(lambda (ctx) (progv ...))` wrapper, compiles it
   under `(handler-bind ((warning #'muffle-warning)) ...)`, and
   stores the compiled function plus the free-vars list and
   original source.
   *Verify:* round-trip tests —
   - `(compile-form '(+ x y))` produces a struct whose
     `compiled-form-fn` returns 5 when called with
     `'((x . 2) (y . 3))`.
   - `compiled-form-free-vars` matches the walker's output.
   - Missing alist key signals an unbound-variable condition at
     call time.

4. **Reroute `compile-template` through `compile-form`.** ELP's
   template body is, after `build-template-body`, just an sexp.
   Drop the inline `progv` wrapper from `compile-template` and
   delegate to `compile-form`. Existing template tests should
   continue to pass unchanged.
   *Verify:* full FiveAM suite passes; manual smoke of the CLI on
   a fixture template matches pre-refactor output.

5. **Export public API and document.** Add `compile-form`,
   `compiled-form`, `compiled-form-fn`, `compiled-form-free-vars`,
   `compiled-form-source` to `:export` in the `elp` package. Add a
   short README section "Form introspection" with a runnable
   example showing the consuming-project use case (enumerate vars,
   then bind and call). Reference the originating motivation.

## Sequencing

Commits 1–3 stand on their own and could land before the consuming
project's API is finalized — they only add a new internal value
type and helper. Commit 4 is the integration step where regressions
could surface; keep the existing template suite green as the gate.
Commit 5 (the export) should wait until the consuming project is
ready to call it; if it's not, ship 1–4 with the symbols internal
and flip the exports later. Avoids designing the public surface in
a vacuum.

Estimated total: ~40 LoC of production code plus tests. The reason
this fits in 40 LoC instead of 150 is that we own no walker logic.

## Decisions (post-landing)

Two course-corrections landed during implementation that are worth
calling out — the plan above doesn't anticipate either:

1. **Lexical bindings instead of PROGV.** The plan described a
   `(progv (mapcar #'car ctx) (mapcar #'cdr ctx) ,form)` wrapper
   carried over from `compile-template`'s shape. That requires the
   free vars to be specials, which forced `(declare (special …))`
   and re-introduced muffle-warning hacks. Worse, `(setf x 42)`
   inside template bodies (an actual existing pattern,
   `simple-code-block-rendering`) wrote to the *global* symbol-value
   cell of unbound specials, leaking state into the host image and
   re-classifying the symbol as special on every subsequent walker
   call.

   Both `compile-form` and `build-template-lambda` now use a
   `(let ((var (let ((cell (assoc 'var ctx))) (unless cell (error
   'unbound-variable :name 'var)) (cdr cell))) …) ,body)` prologue.
   Lexical scope, no global pollution, no `(declare (special …))`,
   no muffle-warning, and `(setf var …)` inside the body modifies
   the local binding only. Templates that used to rely on
   `setf`-of-undefined-special as a poor-man's local now need to
   include the var in their context-alist (even as `nil`); the
   trim test fixtures and `simple-code-block-rendering` were
   updated accordingly.

2. **`hu.dwim.walker` annotates symbols and cons cells with
   source-tracking info that primes SBCL's "unknown variable"
   warnings.** Two consequences:
   - The form spliced into the compiled lambda is `copy-tree`'d to
     detach it from those annotations on the cons cells.
   - The walker's own `hu.dwim.walker:undefined-reference` warnings
     are muffled inside `form-free-vars` — they're expected at this
     layer (the whole point is to enumerate them). SBCL's own
     compile-time warnings flow through unaffected.

   The bare-symbol case (`(compile-form 'x)`) still leaves
   walker-state on the symbol that SBCL reads as "X is an unknown
   reference," but the muffle inside `form-free-vars` keeps that
   warning from reaching the user.

3. **Plan commit 4 (reroute `compile-template` through
   `compile-form`) was deferred.** The two paths use the same
   lexical-binding shape and the same walker call, but
   `build-template-lambda`'s wrapper has additional mmap/error-
   handling concerns that don't compose cleanly with `compile-form`'s
   single-purpose lambda shape. Both paths walk for free vars
   independently. Possible future cleanup; no consumer-project
   value to chase it now.

## Related plans

- `parameterized-compiled-template.md` — the originating plan.
  Whatever follow-up section that plan currently has about
  reintroducing the walker should be replaced with a one-line
  pointer to this file.
- `swank-elp-source-locations.md` (issue #5) — would attach
  `source-pathname` / `compiled-at` metadata. If both are in flight
  simultaneously, that plan can extend `compiled-form` with those
  slots rather than introducing a parallel value type.
