# ELP editor support

Two parallel paths for editing `.elp` files in Neovim, sharing the
same filename-based subtype detection: tree-sitter (better — gives
injections, text objects, runs vlime cleanly inside `<% %>`) and a
vim regex syntax fallback (works without `tree-sitter-cli` or any
parser build).

The fallback is loaded unconditionally; tree-sitter takes precedence
when its `elp` parser is installed.

```
editor/
├── nvim/
│   ├── ftdetect/elp.vim       `*.elp` → filetype `elp`
│   ├── ftplugin/elp.lua       sets vim.b.elp_host from filename
│   ├── plugin/elp.lua         registers `#elp-host!` query directive
│   ├── syntax/elp.vim         regex syntax + subtype dispatch
│   ├── lua/elp/init.lua       filename → tree-sitter-parser map
│   └── queries/elp/
│       ├── highlights.scm     delimiter highlights
│       └── injections.scm     `(code) → commonlisp`,
│                              `(content) → vim.b.elp_host`
└── tree-sitter-elp/
    ├── grammar.js             minimal ERB-subset grammar
    └── queries/
        └── highlights.scm     parser-level highlights
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
(`json`, `yaml`, `toml`, `xml`, `lua`, `sh`, …) resolves directly. The
two alias maps differ — `editor/nvim/syntax/elp.vim` maps to vim
syntax names (`caddyfile`, `systemd`), `editor/nvim/lua/elp/init.lua`
maps to tree-sitter parser names (`caddy`, `ini`) — because the names
sometimes diverge and there's no tree-sitter equivalent for some
syntaxes.

To extend the tree-sitter map without forking, call
`require("elp").register_host("tf", "terraform")` in your config
before opening any `.elp` file.

Lisp inside `<% %>` / `<%= %>` always works regardless of subtype;
`<%# %>` is treated as a comment.

## Install

The instructions below assume Neovim with **lazy.nvim** (LazyVim
distribution) and **nvim-treesitter on its `main` branch (v1.x)**.
That's the only configuration this has been verified against — other
plugin managers and the legacy `master` branch of nvim-treesitter use
different APIs and aren't documented here.

Drop a plugin spec like this into your config (e.g.
`~/.config/nvim/lua/plugins/elp.lua`):

```lua
return {
  -- ELP runtime files: ftdetect, syntax, ftplugin, plugin, queries,
  -- lua module. `lazy = false` so the runtimepath registration
  -- happens before nvim processes command-line file args; otherwise
  -- opening a `.elp` file directly from the shell finishes BufRead
  -- before the plugin loads, and the buffer comes up without
  -- highlighting until you `:e!`.
  {
    "ramfjord/elp",
    name = "elp-editor",
    lazy = false,
    config = function(plugin)
      vim.opt.runtimepath:append(plugin.dir .. "/editor/nvim")
      vim.filetype.add({ extension = { elp = "elp" } })
    end,
  },

  -- tree-sitter parser registration. Requires `tree-sitter` CLI on
  -- PATH (`npm i -g tree-sitter-cli` or `pacman -S tree-sitter-cli`).
  {
    "nvim-treesitter/nvim-treesitter",
    branch = "main",
    opts = function(_, opts)
      local elp_dir = require("lazy.core.config").plugins["elp-editor"].dir
      local grammar = elp_dir .. "/editor/tree-sitter-elp"

      -- nvim-treesitter wipes and re-requires the parsers module on
      -- every install/update (see install.lua's reload_parsers), so
      -- one-shot mutation gets flushed before the lookup runs. The
      -- reload fires `User TSUpdate` afterward — register on that
      -- and once eagerly to cover both startup and reloads.
      local function register()
        require("nvim-treesitter.parsers").elp = {
          install_info = {
            path = grammar,
            generate = true,
            generate_from_json = false,
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
- `:Inspect` outside the tags shows the host-language injection
  (e.g. `caddy` in `Caddyfile.elp`)
- `:checkhealth nvim-treesitter` lists `elp` as installed

For any host language whose tree-sitter parser isn't installed yet
(`caddy`, `make`, `ini`, etc.), `:TSInstall <parser>` once.

## How the host-language injection works

`<% %>` regions are easy: a static query in
`queries/elp/injections.scm` injects `commonlisp` unconditionally.

The outer text is harder — the host language is determined per file
(`Caddyfile.elp` → caddy, `Makefile.elp` → make), and tree-sitter
injection queries are static. The plugin solves this with a custom
query directive:

1. `ftplugin/elp.lua` runs once per buffer, computes the host from
   the filename via `lua/elp/init.lua`, and stashes it in
   `vim.b.elp_host`.
2. `plugin/elp.lua` registers a custom directive `#elp-host!` that
   reads `vim.b.elp_host` at query time and sets the injection
   language.
3. `queries/elp/injections.scm` uses the directive on `(content)`
   captures.

This is the tree-sitter equivalent of the `b:elp_subtype` +
`:syntax include` mechanism that `syntax/elp.vim` has used all
along. ftplugin runs before tree-sitter constructs the parser, so
highlighting attaches correctly on first open — no `:e!` needed.

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
