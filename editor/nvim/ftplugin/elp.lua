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

-- K outside <% %>: fall through to vim's builtin K, which runs
-- `&keywordprg` with <cword>. Default is `:Man`, the right answer
-- for most ELP host languages (mkdir/awk/sed/make in section 1,
-- Caddyfile/systemd.service in section 5). Inside code, hand off
-- to LSP hover for Lisp docs.
--
-- The LSP-layer gate in swank-lsp.lua already short-circuits hover
-- requests outside <% %> — but a short-circuited hover shows
-- "No information available", not a man page. This binding is
-- the one explicit UX override that turns "no LSP answer" into
-- "fall through to keywordprg" for K specifically.
vim.keymap.set("n", "K", function()
  if elp.cursor_in_code() then
    vim.lsp.buf.hover()
  else
    vim.cmd("normal! K")
  end
end, { buffer = 0, desc = "elp: Lisp hover inside <% %>, keywordprg outside" })
