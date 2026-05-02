# ELP editor support

Two parallel paths for editing `.elp` files in Neovim, with the same
subtype-detection model: tree-sitter (better — gives injections, text
objects, runs vlime cleanly inside `<% %>`) and a vim regex syntax
fallback (works without `tree-sitter-cli` or any parser build).

The fallback is loaded unconditionally; tree-sitter takes precedence
when its `elp` parser is installed.

```
editor/
├── nvim/
│   ├── ftdetect/elp.vim    `*.elp` → filetype `elp`
│   └── syntax/elp.vim      regex syntax + subtype dispatch
└── tree-sitter-elp/
    ├── grammar.js          minimal ERB-subset grammar
    └── queries/
        ├── highlights.scm  delimiter highlights
        └── injections.scm  injects commonlisp into `(code)`
```

## Subtype detection

Both paths use the filename to decide what host language to highlight
*outside* the tags:

| Filename                | Subtype     |
| ----------------------- | ----------- |
| `service.yml.elp`       | yaml        |
| `Caddyfile.elp`         | caddy       |
| `Makefile.elp`          | make        |
| `foo.json.elp`          | json        |
| `foo.service.elp`       | systemd/ini |

Anything where the extension already matches the syntax/parser name
(`json`, `yaml`, `toml`, `xml`, `lua`, `sh`, …) resolves directly. Add
to the alias map for `name → vim-syntax-name` (regex path) or `name →
tree-sitter-parser-name` (tree-sitter path). The two maps differ
because parser names sometimes diverge from vim runtime names (e.g.
`caddy` vs `caddyfile`, no tree-sitter `systemd` parser → `ini` is the
passable approximation).

Lisp inside `<% %>` / `<%= %>` always works regardless of subtype;
`<%# %>` is treated as a comment.

## Install

The instructions below assume Neovim with **lazy.nvim** (LazyVim
distribution) and **nvim-treesitter on its `main` branch (v1.x)**.
That's the only configuration this has been verified against — other
plugin managers and the legacy `master` branch of nvim-treesitter use
different APIs and aren't documented here.

Drop a plugin spec like this into your config (e.g.
`~/.config/nvim/lua/plugins/elp.lua`). It clones this repo so both
the vim runtime files (ftdetect/syntax) and the tree-sitter grammar
live under the same plugin dir.

```lua
return {
  -- vim regex syntax + ftdetect — works without tree-sitter.
  -- `lazy = false` so the runtimepath/filetype registration happens
  -- before nvim processes command-line file args; otherwise opening
  -- a `.elp` file directly from the shell finishes BufRead before
  -- the plugin loads, and the buffer comes up without highlighting
  -- until you `:e!`.
  {
    "ramfjord/elp",
    name = "elp-editor",
    lazy = false,
    config = function(plugin)
      vim.opt.runtimepath:append(plugin.dir .. "/editor/nvim")
      vim.filetype.add({ extension = { elp = "elp" } })
    end,
  },

  -- tree-sitter parser registration (optional but recommended)
  -- Requires `tree-sitter` CLI on PATH (`npm i -g tree-sitter-cli` or
  -- `pacman -S tree-sitter-cli`).
  {
    "nvim-treesitter/nvim-treesitter",
    branch = "main", -- assumes nvim-treesitter v1 (`main` branch)
    opts = function(_, opts)
      local elp_dir = require("lazy.core.config").plugins["elp-editor"].dir
      local grammar = elp_dir .. "/editor/tree-sitter-elp"

      -- nvim-treesitter wipes and re-requires the parsers module on
      -- every install/update (see install.lua's reload_parsers), so a
      -- one-shot mutation here gets flushed before the lookup runs.
      -- The reload fires `User TSUpdate` afterward — register on that
      -- and once eagerly to cover both startup and reloads.
      local function register()
        require("nvim-treesitter.parsers").elp = {
          install_info = {
            path = grammar,
            generate = true,
            generate_from_json = false, -- repo ships grammar.js, not src/grammar.json
            queries = "queries",
          },
          tier = 3,
        }
      end
      register()
      vim.api.nvim_create_autocmd("User", {
        pattern = "TSUpdate",
        callback = register,
      })

      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, { "elp", "commonlisp" })
    end,
  },
}
```

After restart, LazyVim's treesitter config picks up `elp` in
`ensure_installed` and runs `tree-sitter generate` + build. Verify:

- `:set ft?` on a `.elp` buffer reports `elp`
- `:InspectTree` shows `directive` / `output_directive` / `comment_directive` nodes
- `:Inspect` inside `<% %>` shows `commonlisp` injection captures
- `:checkhealth nvim-treesitter` lists `elp` as installed

For the host-language injection in `(content)` regions, the static
`injections.scm` only covers `(code) → commonlisp` — the host language
is per-buffer, so set it dynamically:

```lua
local subtype_aliases = {
  yml = "yaml", rb = "ruby", js = "javascript", ts = "typescript",
  md = "markdown", htm = "html",
  Makefile = "make", Dockerfile = "dockerfile", Caddyfile = "caddy",
  service = "ini", timer = "ini", socket = "ini",
  mount = "ini", path = "ini", target = "ini",
}

local function detect_subtype(filename)
  local ext = filename:match("%.(%w+)%.elp$")
              or filename:match("^(%w+)%.elp$")
  if not ext then return nil end
  return subtype_aliases[ext] or ext:lower()
end

-- Pattern semantics differ between events: FileType matches the
-- filetype name ("elp"), BufEnter matches the filename ("*.elp").
-- A single pattern can't satisfy both, and FileType has to fire
-- before nvim-treesitter constructs the parser — otherwise the
-- parser caches an injection query without the host-language entry,
-- and you have to `:e!` to recreate it.
local function set_injections(buf)
  if vim.bo[buf].filetype ~= "elp" then return end
  local name = vim.api.nvim_buf_get_name(buf)
  local subtype = detect_subtype(vim.fn.fnamemodify(name, ":t"))
  local q = [[
((code) @injection.content
 (#set! injection.language "commonlisp")
 (#set! injection.combined))
]]
  if subtype then
    q = q .. string.format([[
((content) @injection.content
 (#set! injection.language %q)
 (#set! injection.combined))
]], subtype)
  end
  pcall(vim.treesitter.query.set, "elp", "injections", q)
end

vim.api.nvim_create_autocmd("FileType", {
  pattern = "elp",
  callback = function(ev) set_injections(ev.buf) end,
})

vim.api.nvim_create_autocmd("BufEnter", {
  pattern = "*.elp",
  callback = function(ev) set_injections(ev.buf) end,
})
```

Caveat: `vim.treesitter.query.set` is global. With one `.elp` file
open at a time this is fine; with two open of different subtypes, the
most-recently-entered one wins for both buffers until you switch back.
Acceptable trade-off for now; nvim doesn't expose per-buffer injection
queries cleanly.

For any host language whose tree-sitter parser isn't installed yet
(`caddy`, `make`, `ini`, etc.), `:TSInstall <parser>` once.

## Status of the plan

Tracks `plans/elp-nvim-filetype.md`:

- [x] ftdetect + filetype registration
- [x] Tree-sitter grammar (`<%`, `<%=`, `<%#`, `-` trim variants)
- [x] Lisp injection inside `(code)`; host-language injection inside
      `(content)` driven per-buffer by filename
- [ ] vlime keymap activation inside Lisp regions (form-at-point,
      arglist, eval-defun) — open question whether vlime's reader
      respects injection boundaries
- [ ] Polish: ftplugin (`commentstring`, `iskeyword`)

## Other editors

Not yet. Other editors / plugin managers would need their own
integration; nothing here has been verified outside lazy.nvim with
nvim-treesitter `main`.
