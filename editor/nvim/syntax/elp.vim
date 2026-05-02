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
  let b:elp_subtype = matchstr(expand("%:t"), '\c\.\zs\w\+\ze\.elp\>')
  if b:elp_subtype == ''
    let b:elp_subtype = matchstr(substitute(expand("%:t"), '\.elp$', '', ''), '\.\zs\w\+$')
  endif
endif

" Aliases: extension -> syntax filename
let s:elp_subtype_aliases = {
      \ 'yml':  'yaml',
      \ 'rb':   'ruby',
      \ 'js':   'javascript',
      \ 'ts':   'typescript',
      \ 'md':   'markdown',
      \ 'htm':  'html',
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
