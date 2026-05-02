-- Custom tree-sitter directive that pulls the injection language for
-- `(content)` regions out of the current buffer's `vim.b.elp_host`.
-- Registered once at startup; consumed by queries/elp/injections.scm.
--
-- This is the tree-sitter equivalent of what syntax/elp.vim already
-- does on the regex side via `b:elp_subtype` + `:syntax include`.
-- Without it, ELP would need a separate `injections.scm` per host
-- language (impossible — the host is determined per file, not per
-- grammar).

if vim.g.loaded_elp then return end
vim.g.loaded_elp = true

vim.treesitter.query.add_directive("elp-host!", function(_, _, bufnr, _, metadata)
  local host = vim.b[bufnr].elp_host
  if host then
    metadata["injection.language"] = host
  end
end, { all = true })
