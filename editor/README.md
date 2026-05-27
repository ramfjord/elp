# ELP editor support

Neovim is the reference setup — tree-sitter with full host-language
injection, plus a regex syntax fallback. Emacs (30+) has parallel
tree-sitter support sharing the same grammar.

```
editor/
├── nvim/                      reference setup, full injection
├── emacs/elp-ts-mode.el       treesit mode for `.elp' files
└── tree-sitter-elp/           shared grammar (used by both)
    ├── grammar.js             minimal ERB-subset grammar
    └── queries/highlights.scm parser-level highlights
```

## Neovim

Two parallel paths sharing the same filename-based subtype detection:
tree-sitter (better — injections, text objects, runs vlime cleanly
inside `<% %>`) and a vim regex syntax fallback (works without
`tree-sitter-cli` or any parser build). Fallback loads
unconditionally; tree-sitter takes precedence when its `elp` parser
is installed.

```
nvim/
├── ftdetect/elp.vim       `*.elp` → filetype `elp`
├── ftplugin/elp.lua       sets vim.b.elp_host from filename
├── plugin/elp.lua         registers `#elp-host!` query directive
├── syntax/elp.vim         regex syntax + subtype dispatch
├── lua/elp/init.lua       filename → tree-sitter-parser map
└── queries/elp/
    ├── highlights.scm     delimiter highlights
    └── injections.scm     `(code) → commonlisp`,
                           `(content) → vim.b.elp_host`
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

Tested only on **LazyVim**, which bundles **lazy.nvim** and
**nvim-treesitter on its `main` branch (v1.x)**. Other plugin managers
and the legacy `master` branch of nvim-treesitter aren't documented
here. Also requires `tree-sitter` CLI on PATH (`npm i -g
tree-sitter-cli` or `pacman -S tree-sitter-cli`) for the parser build.

Drop into `~/.config/nvim/lua/plugins/elp.lua`:

```lua
return {
  { "ramfjord/elp", lazy = false },
}
```

`lazy = false` so the plugin's runtimepath registration finishes
before nvim processes command-line file args — otherwise opening a
`.elp` file directly from the shell finishes BufRead before the
plugin loads, and the buffer comes up without highlighting until you
`:e!`.

Then add `"elp"` (and any host-language parsers you'll use, e.g.
`"caddy"`, `"make"`) to your nvim-treesitter `ensure_installed` list.
The plugin registers the parser source itself; you only opt in to
having it installed.

Verify:

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

## Emacs (30+)

Requires Emacs built with tree-sitter (`(treesit-available-p)` → `t`)
and a C compiler on PATH for the grammar build.  Tested on Emacs
30.2; should also work on 29 but no longer verified there.

Multi-language by construction: `<% %>` tags inject `commonlisp`,
the outer text injects a host language resolved from the filename
(`service.yml.elp` → yaml, `Makefile.elp` → make, etc.) via
`elp-ts-mode-host-language-alist`.  Host font-lock is **lifted from
the host's own `*-ts-mode` `--font-lock-settings`**, so yaml/bash/
json/etc. highlighting inside `.elp` files matches what you'd see
opening a plain `.yml`/`.sh`/`.json` — no reimplementation.

Load the mode (from a local checkout):

```elisp
(add-to-list 'load-path "/path/to/elp/editor/emacs")
(require 'elp-ts-mode)
;; M-x treesit-install-language-grammar RET elp RET
;; (the mode self-registers the source — no URL to copy)
```

Or with `use-package`:

```elisp
(use-package elp-ts-mode
  :load-path "/path/to/elp/editor/emacs"
  :mode "\\.elp\\'")
```

Then install any host grammars you'll use.  Emacs ships a default
`treesit-language-source-alist` covering the common ones; otherwise
add entries (see this repo's `~/.emacs.d/init.el` example).  Typical
set for templates in this repo:

| Grammar    | Source repo                                 |
| ---------- | ------------------------------------------- |
| commonlisp | `theHamsta/tree-sitter-commonlisp`          |
| yaml       | `ikatyang/tree-sitter-yaml`                 |
| bash       | `tree-sitter/tree-sitter-bash`              |
| json       | `tree-sitter/tree-sitter-json`              |
| dockerfile | `camdencheek/tree-sitter-dockerfile`        |
| make       | `alemuller/tree-sitter-make`                |
| ini        | `justinmk/tree-sitter-ini` (for `*.service.elp`) |

Install with `M-x treesit-install-language-grammar RET <name> RET`
for each — the `.so` files land in `~/.emacs.d/tree-sitter/` and
become available across all your Emacs sessions, not just for ELP.

**Graceful degradation.**  Any host grammar that isn't installed is
silently skipped — that filename's outer text renders as plain
text, but ELP tags and (if `commonlisp` is installed) Lisp inside
them still highlight.  Some host languages have no upstream
tree-sitter grammar at all; files with those extensions get
plain-text outer content.

Verify:

- `M-x elp-ts-mode` in a `.elp` buffer doesn't error
- `M-x treesit-explore-mode` shows `template` / `directive` /
  `output_directive` / `comment_directive` nodes
- `<% %>` delimiters get `font-lock-keyword-face`
- Inside `<%= %>`: strings/numbers/`:keywords` get Lisp faces
- Outside: yaml keys, JSON keys, etc. get their host-mode faces

**Common Lisp font-lock is intentionally minimal** (strings,
numbers, comments, `:keywords`) because no `commonlisp-ts-mode`
ships in Emacs, so there's no `--font-lock-settings` to lift —
unlike yaml/bash/json which we borrow wholesale.  Emacs has
beautiful Lisp highlighting elsewhere via `lisp-mode`, but that's
regex/`syntax-table`-based and doesn't compose with the treesit
multi-language machinery.
