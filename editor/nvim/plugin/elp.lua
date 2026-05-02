if vim.g.loaded_elp then return end
vim.g.loaded_elp = true

-- Custom tree-sitter directive that pulls the injection language for
-- `(content)` regions out of the current buffer's `vim.b.elp_host`.
-- Consumed by queries/elp/injections.scm.
--
-- This is the tree-sitter equivalent of what syntax/elp.vim does on
-- the regex side via `b:elp_subtype` + `:syntax include`. Without it,
-- ELP would need a separate `injections.scm` per host language —
-- impossible, since the host is determined per file, not per grammar.
vim.treesitter.query.add_directive("elp-host!", function(_, _, bufnr, _, metadata)
  local host = vim.b[bufnr].elp_host
  if host then
    metadata["injection.language"] = host
  end
end, { all = true })

-- nvim-treesitter custom-parser registration. Pattern from the
-- upstream README's "Adding custom languages":
--   https://github.com/nvim-treesitter/nvim-treesitter#adding-custom-languages
--
-- Registering inside the plugin (rather than asking every user to
-- paste the snippet) keeps downstream installs to a single lazy.nvim
-- line. pcall skips silently when nvim-treesitter isn't loaded, so a
-- user who doesn't use it still gets the ftdetect/syntax/queries half
-- of the plugin without an error.
local function register_parser()
  local ok, parsers = pcall(require, "nvim-treesitter.parsers")
  if not ok then return end
  parsers.elp = {
    install_info = {
      url = "https://github.com/ramfjord/elp",
      -- Grammar lives in a subdirectory of the monorepo.
      location = "editor/tree-sitter-elp",
      -- grammar.js doesn't ship a pre-generated src/parser.c, so
      -- nvim-treesitter has to run `tree-sitter generate`.
      generate = true,
      generate_from_json = false,
      queries = "queries",
    },
    tier = 3,
  }
end

-- The eager call covers code paths that read `parsers.elp` before
-- any TSUpdate fires (e.g. ensure_installed on a cold cache). The
-- autocmd is still required: install/update routines wipe and
-- re-require the parsers module (see install.lua's reload_parsers
-- in the nvim-treesitter source), so the eager assignment alone
-- gets flushed on every update.
register_parser()
vim.api.nvim_create_autocmd("User", {
  pattern = "TSUpdate",
  callback = register_parser,
})
