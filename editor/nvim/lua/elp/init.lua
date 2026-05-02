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

return M
