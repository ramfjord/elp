-- Resolve the host language once per buffer and stash it under
-- `vim.b.elp_host` for the injection directive in plugin/elp.lua to
-- read. Doing this in ftplugin (not BufEnter) means it's set before
-- the tree-sitter parser is constructed, which is what makes
-- highlighting attach on first open without an `:e!`.

local elp = require("elp")
local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t")
local token = elp.detect_token(name)
local host = elp.resolve_host(token)
if host then
  vim.b.elp_host = host
end
