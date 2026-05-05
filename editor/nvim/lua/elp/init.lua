-- Filename → tree-sitter parser name. Single source of truth for
-- ELP's host-language injection. Entries only exist where the
-- filename token differs from the parser name (e.g. yml→yaml,
-- Caddyfile→caddy). Tokens that already match a parser name (json,
-- yaml, toml, lua, sh, …) resolve via fallthrough — no entry needed.
local hosts = {
  yml = "yaml",
  rb = "ruby",
  js = "javascript",
  ts = "typescript",
  md = "markdown",
  htm = "html",
  sh = "bash",
  bash = "bash",
  zsh = "bash",
  env = "bash",
  tf = "terraform",
  tfvars = "terraform",
  Makefile = "make",
  Dockerfile = "dockerfile",
  Caddyfile = "caddy",
  nginx = "nginx",
  -- No tree-sitter "systemd" parser; ini is the closest passable fit.
  service = "ini",
  timer = "ini",
  socket = "ini",
  mount = "ini",
  path = "ini",
  target = "ini",
}

local M = {}

--- Detect the host-language token from a `.elp` filename.
--- `service.yml.elp` → "yml", `Makefile.elp` → "Makefile", `foo.elp` → nil.
function M.detect_token(filename)
  return filename:match("%.(%w+)%.elp$")
      or filename:match("^(%w+)%.elp$")
end

--- Resolve a token to a tree-sitter parser name, or nil if the
--- token doesn't map to anything plausible.
function M.resolve_host(token)
  if not token then return nil end
  return hosts[token] or token:lower()
end

--- Extend the alias map. For users whose filename convention isn't
--- covered out of the box (`foo.tf.elp` → terraform, etc.).
function M.register_host(token, parser_name)
  hosts[token] = parser_name
end

--- Is `(row, col)` (0-indexed) in `bufnr` inside a `<% %>` code
--- region? Used to gate Lisp-LSP behavior to Lisp regions on .elp
--- buffers without per-feature plumbing.
---
--- Prefers the tree-sitter `elp` parser; falls back to a tag-scan
--- when it isn't available so the gate still works on regex-only
--- setups.
function M.position_in_code(bufnr, row, col)
  bufnr = bufnr or 0

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "elp")
  if ok and parser then
    local trees = parser:parse()
    local tree = trees and trees[1]
    if tree then
      local node = tree:root():descendant_for_range(row, col, row, col)
      while node do
        if node:type() == "code" then return true end
        node = node:parent()
      end
      return false
    end
  end

  -- Fallback: scan buffer text from start to (row, col) for the last
  -- unclosed `<%`. Only counts open/close tokens; doesn't try to
  -- understand strings or comments. Good enough as a fallback.
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, row + 1, false)
  if #lines == 0 then return false end
  lines[#lines] = lines[#lines]:sub(1, col)
  local text = table.concat(lines, "\n")
  local in_tag = false
  local i, n = 1, #text
  while i <= n do
    local two = text:sub(i, i + 1)
    if two == "<%" then in_tag = true; i = i + 2
    elseif two == "%>" then in_tag = false; i = i + 2
    else i = i + 1 end
  end
  return in_tag
end

--- Cursor-position convenience wrapper around `position_in_code`.
function M.cursor_in_code(bufnr)
  bufnr = bufnr or 0
  local pos = vim.api.nvim_win_get_cursor(0)
  return M.position_in_code(bufnr, pos[1] - 1, pos[2])
end

--- Return BUFNR's text with non-code regions blanked to whitespace.
---
--- Used by host-language LSP clients (e.g. swank-lsp.nvim) to feed an
--- ELP buffer through a server that only understands the host
--- language. The transform preserves byte offsets and newlines, so
--- positions in the original buffer map 1:1 to positions in the
--- output — no translation needed on responses.
---
--- Specifically:
---   - Bytes inside `code` nodes whose parent is `directive` or
---     `output_directive` are kept verbatim.
---   - Everything else (literal content, tag delimiters `<%`/`%>`,
---     trim markers, comment directives) is replaced with spaces,
---     except newlines, which are preserved.
---
--- Requires the tree-sitter `elp` parser. Returns nil if it isn't
--- available — callers should fall back to sending the original text
--- untransformed (or skip the LSP feature) rather than guessing.
function M.extract_code_text(bufnr)
  bufnr = bufnr or 0

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "elp")
  if not (ok and parser) then return nil end
  local tree = (parser:parse() or {})[1]
  if not tree then return nil end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #lines == 0 then return "" end

  -- Start with every line blanked out; we'll splice keep-ranges back in.
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = string.rep(" ", #line)
  end

  -- Replace the blanked text in OUT[start_row..end_row] with the
  -- original bytes from LINES, only within the given column range.
  -- Operates in-place on OUT. All coords are 0-indexed.
  local function splice_keep(start_row, start_col, end_row, end_col)
    for row = start_row, end_row do
      local original_line = lines[row + 1] or ""
      local keep_from_col = (row == start_row) and start_col or 0
      local keep_to_col   = (row == end_row) and end_col or #original_line
      local blanked = out[row + 1] or ""
      out[row + 1] = blanked:sub(1, keep_from_col)
                  .. original_line:sub(keep_from_col + 1, keep_to_col)
                  .. blanked:sub(keep_to_col + 1)
    end
  end

  local function visit(node)
    if node:type() == "code" then
      local parent = node:parent()
      local pt = parent and parent:type()
      if pt == "directive" or pt == "output_directive" then
        splice_keep(node:range())
      end
    end
    for child in node:iter_children() do visit(child) end
  end
  visit(tree:root())

  return table.concat(out, "\n")
end

return M
