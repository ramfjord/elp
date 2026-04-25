# TODOs

- Live swank integration: load generated template code into a running image with source locations pointing back into the `.elp` file, so SLIME's M-., arglist, completion, and the debugger work from inside `<% ... %>` regions and runtime/compile errors land on the right `.elp` line automatically. Complementary to `elp-template-error` (which covers errors inside the engine itself).
- String-based rendering: `render` currently only accepts a pathname. Add a method that takes a template string directly, for callers that already have the source in memory.
- Empty expressions (`<%= %>`) are silently skipped. Decide whether this should be an error, a no-op (current), or render as the empty string explicitly.
