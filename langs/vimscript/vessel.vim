" Hello World Tree — Vim Script adapter.
"
" Vim Script is a bridge language, and the bridge is a place rather than a translation: it is where a
" person edits the vessel while looking at it. Every other adapter here runs and exits. This one is the
" one you are inside of.
"
" That shapes the design. A function that takes a second to run is fine in an adapter that runs once and
" unacceptable in one bound to a keystroke, so everything here is incremental: a buffer is scanned as it
" is written, and the graph is updated rather than rebuilt.

" ── Guard ─────────────────────────────────────────────────────────────────────
" Sourced twice is a real hazard — a plugin manager reloading, or a second :source by hand. Bailing is
" cheaper than defending every global below.

if exists('g:loaded_hwt_vessel')
  finish
endif
let g:loaded_hwt_vessel = 1

let s:save_cpo = &cpo
set cpo&vim

" ── State ────────────────────────────────────────────────────────────────────
" A dictionary rather than several globals: one namespace, one reset point, and it serialises to JSON
" without translation.

let s:vessel = {
      \ 'nodes': {},
      \ 'order': [],
      \ 'edges': [],
      \ 'seen_edges': {},
      \ }

let s:PATTERNS = {
      \ 'vim': {
      \   'function': '\v^\s*fu%[nction]!?\s+([A-Za-z_][A-Za-z0-9_#:]*)',
      \   'command':  '\v^\s*com%[mand]!?\s+([A-Za-z][A-Za-z0-9]*)',
      \   'variable': '\v^\s*let\s+([gbwtslav]:)?([A-Za-z_][A-Za-z0-9_]*)',
      \   'runtime':  '\v^\s*runtime\s+(.+)',
      \ },
      \ 'lua': {
      \   'function': '\v^\s*function\s+([A-Za-z_][A-Za-z0-9_.:]*)',
      \ },
      \ }

" ── Node and edge ────────────────────────────────────────────────────────────

function! s:Node(id, kind, label, line) abort
  return {'id': a:id, 'source': 'vimscript', 'kind': a:kind, 'label': a:label, 'line': a:line}
endfunction

function! s:AddNode(id, kind, label, line) abort
  if has_key(s:vessel.nodes, a:id)
    return 0
  endif
  let s:vessel.nodes[a:id] = s:Node(a:id, a:kind, a:label, a:line)
  call add(s:vessel.order, a:id)
  return 1
endfunction

" Deduplicate on the triple. A graph that admits duplicate edges is not queryable, it is just large.
function! s:Link(from, to, kind) abort
  let l:key = a:from . "\x1f" . a:to . "\x1f" . a:kind
  if has_key(s:vessel.seen_edges, l:key)
    return
  endif
  let s:vessel.seen_edges[l:key] = 1
  call add(s:vessel.edges, {'from': a:from, 'to': a:to, 'kind': a:kind})
endfunction

" ── Extraction ───────────────────────────────────────────────────────────────

" Scan the current buffer into the vessel. Idempotent, because the buffer may be rescanned on every
" write and a scan that adds nodes twice makes the graph lie.
function! hwt#vessel#scan(...) abort
  let l:lines = getline(1, '$')
  let l:file = expand('%:p')
  let l:file_id = l:file . ':file'

  call s:AddNode(l:file_id, 'file', fnamemodify(l:file, ':t'), 0)

  let l:patterns = s:PATTERNS.vim
  let l:lnum = 0

  for l:line in l:lines
    let l:lnum += 1

    " Comments are not declarations.
    if l:line =~# '^\s*"'
      continue
    endif

    let l:name = matchlist(l:line, l:patterns.function)
    if !empty(l:name)
      let l:id = l:file . ':' . l:name[1]
      call s:AddNode(l:id, 'function', l:name[1], l:lnum)
      call s:Link(l:file_id, l:id, 'contains')
      continue
    endif

    let l:cmd = matchlist(l:line, l:patterns.command)
    if !empty(l:cmd)
      let l:id = l:file . ':' . l:cmd[1]
      call s:AddNode(l:id, 'command', l:cmd[1], l:lnum)
      call s:Link(l:file_id, l:id, 'contains')
      continue
    endif

    let l:rt = matchlist(l:line, l:patterns.runtime)
    if !empty(l:rt)
      let l:target = substitute(l:rt[1], '[./]', '_', 'g')
      let l:id = 'import:' . l:target
      call s:AddNode(l:id, 'import', l:rt[1], l:lnum)
      call s:Link(l:file_id, l:id, 'imports')
    endif
  endfor

  return len(s:vessel.order)
endfunction

" ── Digest ───────────────────────────────────────────────────────────────────
" What a person reads instead of the graph. Counts by kind, and nothing else, because that is what a
" status line has room for.

function! hwt#vessel#digest() abort
  let l:kinds = {}
  for l:id in s:vessel.order
    let l:kind = s:vessel.nodes[l:id].kind
    let l:kinds[l:kind] = get(l:kinds, l:kind, 0) + 1
  endfor

  let l:parts = []
  for l:kind in sort(keys(l:kinds))
    call add(l:parts, l:kind . '=' . l:kinds[l:kind])
  endfor

  return printf('vimscript: %d nodes, %d edges [%s]',
        \ len(s:vessel.order), len(s:vessel.edges), join(l:parts, ', '))
endfunction

" ── The float window ─────────────────────────────────────────────────────────
" The vessel, visible while you edit. This is the piece no other adapter has, because no other adapter
" is running inside the editor.

function! hwt#vessel#float() abort
  call hwt#vessel#scan()

  let l:buf = nvim_create_buf(v:false, v:true)
  let l:lines = [hwt#vessel#digest(), '']

  for l:id in s:vessel.order
    let l:n = s:vessel.nodes[l:id]
    call add(l:lines, printf('  %-10s %s', l:n.kind, l:n.label))
  endfor

  call nvim_buf_set_lines(l:buf, 0, -1, v:false, l:lines)

  let l:width = 54
  let l:height = min([len(l:lines), 20])

  let l:opts = {
        \ 'relative': 'editor',
        \ 'width': l:width,
        \ 'height': l:height,
        \ 'row': 2,
        \ 'col': &columns - l:width - 4,
        \ 'style': 'minimal',
        \ 'border': 'single',
        \ 'title': ' vessel ',
        \ }

  return nvim_open_win(l:buf, v:false, l:opts)
endfunction

" ── Commands ─────────────────────────────────────────────────────────────────
" Two, and no more. A plugin that adds six commands has six things to remember.

command! HwtScan   call hwt#vessel#scan()
command! HwtVessel call hwt#vessel#float()

let &cpo = s:save_cpo
unlet s:save_cpo
