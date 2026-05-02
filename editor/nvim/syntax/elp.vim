" Vim syntax file
" Language:  ELP (ERB-style templates with embedded Common Lisp)
" Modeled on $VIMRUNTIME/syntax/eruby.vim

if exists("b:current_syntax")
  finish
endif

" --- Subtype detection -------------------------------------------------------
" service.yml.elp -> subtype "yml" -> load syntax/yaml.vim underneath.
" Override by setting b:elp_subtype before the syntax loads.

if !exists("b:elp_subtype")
  " service.yml.elp -> "yml"
  let b:elp_subtype = matchstr(expand("%:t"), '\c\.\zs\w\+\ze\.elp\>')
  if b:elp_subtype == ''
    " foo.bar.elp (no .ext.elp match above) -> "bar"
    let b:elp_subtype = matchstr(substitute(expand("%:t"), '\.elp$', '', ''), '\.\zs\w\+$')
  endif
  if b:elp_subtype == ''
    " Makefile.elp / Dockerfile.elp -> "Makefile" / "Dockerfile"
    let b:elp_subtype = matchstr(expand("%:t"), '\v^\w+\ze\.elp$')
  endif
endif

" Aliases: extension/basename -> syntax filename. Only entries where the
" hint differs from the actual syntax/<name>.vim go here; matches like
" foo.json.elp or foo.yaml.elp resolve directly without an alias.
let s:elp_subtype_aliases = {
      \ 'yml':        'yaml',
      \ 'rb':         'ruby',
      \ 'js':         'javascript',
      \ 'ts':         'typescript',
      \ 'md':         'markdown',
      \ 'htm':        'html',
      \ 'sh':         'sh',
      \ 'bash':       'sh',
      \ 'zsh':        'zsh',
      \ 'env':        'sh',
      \ 'tf':         'terraform',
      \ 'tfvars':     'terraform',
      \ 'Makefile':   'make',
      \ 'Dockerfile': 'dockerfile',
      \ 'Caddyfile':  'caddyfile',
      \ 'service':    'systemd',
      \ 'timer':      'systemd',
      \ 'socket':     'systemd',
      \ 'mount':      'systemd',
      \ 'path':       'systemd',
      \ 'target':     'systemd',
      \ 'nginx':      'nginx',
      \ }
if has_key(s:elp_subtype_aliases, b:elp_subtype)
  let b:elp_subtype = s:elp_subtype_aliases[b:elp_subtype]
endif

if b:elp_subtype != ''
  exe "runtime! syntax/" . b:elp_subtype . ".vim"
  unlet! b:current_syntax
endif

" --- Embedded Lisp -----------------------------------------------------------

syn include @elpTop syntax/lisp.vim
unlet! b:current_syntax

" Comment form first so <%# ... %> doesn't get parsed as code.
syn region elpComment matchgroup=elpDelimiter
      \ start=+<%#+ end=+-\?%>+
      \ contains=@Spell containedin=ALL keepend

" Code/expression form: <% ... %>, <%= ... %>, <%- ... -%>, <%-= ... -%>
syn region elpBlock matchgroup=elpDelimiter
      \ start=+<%-\?=\?+ end=+-\?%>+
      \ contains=@elpTop containedin=ALL keepend

" --- Highlight links ---------------------------------------------------------

hi def link elpDelimiter PreProc
hi def link elpComment   Comment

let b:current_syntax = "elp"
