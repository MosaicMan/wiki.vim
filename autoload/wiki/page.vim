" A simple wiki plugin for Vim
"
" Maintainer: Karl Yngve Lervåg
" Email:      karl.yngve@gmail.com
" License:    MIT license
"

function! wiki#page#delete() abort "{{{1
  let l:input_response = input('Delete "' . expand('%') . '" [y]es/[N]o? ')
  if l:input_response !~? '^y' | return | endif

  let l:filename = expand('%:p')
  try
    call delete(l:filename)
  catch /.*/
    echomsg 'wiki Error: Cannot delete "' . expand('%:t:r') . '"!'
    return
  endtry

  call wiki#nav#return()
  execute 'bdelete! ' . escape(l:filename, ' ')
endfunction

"}}}1
function! wiki#page#rename() abort "{{{1
  " Check if current file exists
  if !filereadable(expand('%:p'))
    echom 'wiki Error: Cannot rename "' . expand('%:p')
          \ . '". It does not exist! (New file? Save it before renaming.)'
    return
  endif

  if b:wiki.in_journal
    echom 'Not supported yet.'
    return
  endif

  " Ask if user wants to rename
  if input('Rename "' . expand('%:t:r') . '" [y]es/[N]o? ') !~? '^y'
    return
  endif

  " Get new page name
  let l:new = {}
  let l:new.name = substitute(input('Enter new name: '), '\.wiki$', '', '')
  echon "\r"
  if empty(substitute(l:new.name, '\s*', '', ''))
    echom 'wiki Error: Cannot rename to an empty filename!'
    return
  endif

  " Expand to full path name, check if already exists
  let l:new.path = expand('%:p:h') . '/' . l:new.name . '.wiki'
  if filereadable(l:new.path)
    echom 'wiki Error: Cannot rename to "' . l:new.path
          \ . '". File with that name exist!'
    return
  endif

  " Rename current file to l:new.path
  try
    echom 'wiki: Renaming ' . expand('%:t')
          \ . ' to ' . fnamemodify(l:new.path, ':t')
    if rename(expand('%:p'), l:new.path) != 0
      throw 'Cannot rename!'
    end
    setlocal buftype=nofile
  catch
    echom 'wiki Error: Cannot rename "'
          \ . expand('%:t:r') . '" to "' . l:new.path . '"!'
    return
  endtry

  " Store some info from old buffer
  let l:old = {
        \ 'path' : expand('%:p'),
        \ 'name' : expand('%:t:r'),
        \ 'prev_link' : get(b:, 'wiki_prev_link', ''),
        \}

  " Get list of open wiki buffers
  let l:bufs = map(filter(map(filter(range(1, bufnr('$')),
        \       'buflisted(v:val)'),
        \     'fnamemodify(bufname(v:val), '':p'')'),
        \   'v:val =~# ''.wiki$'''),
        \ '[v:val, getbufvar(v:val, ''wiki.prev_link'')]')

  " Save and close wiki buffers
  for [l:bufname, l:dummy] in l:bufs
    execute 'buffer' fnameescape(l:bufname)
    update
    execute 'bwipeout' fnameescape(l:bufname)
  endfor

  " Update links
  call s:rename_update_links(l:old.name, l:new.name)

  " Restore wiki buffers
  for [l:bufname, l:prev_link] in l:bufs
    if resolve(l:bufname) ==# resolve(l:old.path)
      let l:url = wiki#url#parse(
            \ l:new.name,
            \ { 'origin' : l:old.prev_link })
    else
      let l:url = wiki#url#parse(
            \ fnamemodify(l:bufname, ':t:r'),
            \ { 'prev_link' : l:prev_link })
    endif
    silent call l:url.open()
  endfor
endfunction

" }}}1
function! wiki#page#create_toc(local) abort " {{{1
  let l:entries = wiki#page#gather_toc_entries(a:local)
  if empty(l:entries) | return | endif

  if a:local
    let l:level = l:entries[0].level + 1
    let l:lnum_top = l:entries[0].lnum
    if len(l:entries) <= 1 | return | endif
    let l:entries = l:entries[1:]
    let l:lnum_bottom = l:entries[0].lnum
  else
    let l:level = 1
    let l:lnum_top = 1
    let l:lnum_bottom = get(get(l:entries, 1, {}), 'lnum', line('$'))
  endif

  let l:start = max([l:entries[0].lnum, 0])
  let l:title = get(g:, 'wiki_toc_title', 'Contents')
  let l:header = '*' . l:title . '*'
  let l:re = '\v^(' . repeat('#', l:level) . ' ' . l:title . '|\*' . l:title . '\*)$'

  " Save the window view and syntax setting and disable syntax (makes things
  " much faster)
  let l:winsave = winsaveview()
  let l:syntax = &l:syntax
  setlocal syntax=off

  "
  " Delete TOC if it exists
  "
  for l:lnum in range(l:lnum_top, l:lnum_bottom)
    if getline(l:lnum) =~# l:re
      let l:header = getline(l:lnum)
      let l:start = l:lnum
      let l:end = l:start + (getline(l:lnum+1) =~# '^\s*$' ? 2 : 1)
      while l:end <= l:lnum_bottom && getline(l:end) =~# '^\s*- '
        let l:end += 1
      endwhile

      let l:foldenable = &l:foldenable
      setlocal nofoldenable
      silent execute printf('%d,%ddelete _', l:start, l:end - 1)
      let &l:foldenable = l:foldenable

      break
    endif
  endfor

  "
  " Add updated TOC
  "
  call append(l:start - 1, l:header)
  let l:length = len(l:entries)
  for l:i in range(l:length)
    call append(l:start + l:i, l:entries[l:i].header)
  endfor
  if getline(l:start + l:length + 1) !=# ''
    call append(l:start + l:length, '')
  endif
  if l:header =~# '^#'
    call append(l:start, '')
  endif

  "
  " Restore syntax and view
  "
  let &l:syntax = l:syntax
  call winrestview(l:winsave)
endfunction

" }}}1
function! wiki#page#gather_toc_entries(local) abort " {{{1
  let l:start = 1
  let l:entry = {}
  let l:entries = []
  let l:local = {}
  let l:anchor_stack = []
  let l:lnum_current = line('.')

  "
  " Gather toc entries
  "
  for l:lnum in range(1, line('$'))
    if wiki#u#is_code(l:lnum) | continue | endif

    " Get line - check for header
    let l:line = getline(l:lnum)
    if l:line !~# wiki#rx#header() | continue | endif

    " Parse current header
    let l:level = len(matchstr(l:line, '^#*'))
    let l:header = matchlist(l:line, wiki#rx#header_items())[2]
    if l:header ==# 'Innhald' | continue | endif

    " Update header stack in order to have well defined anchor
    let l:depth = len(l:anchor_stack)
    if l:depth >= l:level
      call remove(l:anchor_stack, l:level-1, l:depth-1)
    endif
    call add(l:anchor_stack, l:header)
    let l:anchor = '#' . join(l:anchor_stack, '#')

    " Start local boundary container
    if empty(l:local) && l:lnum >= l:lnum_current
      let l:local.level = get(l:entry, 'level')
      let l:local.lnum = get(l:entry, 'lnum')
      let l:local.nstart = len(l:entries) - 1
    endif

    " Add the new entry
    let l:entry = {
          \ 'lnum' : l:lnum,
          \ 'level' : l:level,
          \ 'header' : repeat(' ', shiftwidth()*(l:level-1))
          \            . '- ' . wiki#link#template_wiki(l:anchor, l:header),
          \}
    call add(l:entries, l:entry)

    " Set local boundaries
    if !empty(l:local) && !get(l:local, 'done') && l:level <= l:local.level
      let l:local.done = 1
      let l:local.nend = len(l:entries) - 2
    endif
  endfor

  if !has_key(l:local, 'done')
    let l:local.nend = len(l:entries) - 1
  endif

  let l:depth = get(g:, 'wiki_toc_depth', 6)

  if a:local
    let l:entries = l:entries[l:local.nstart : l:local.nend]
    for l:entry in l:entries
      let l:entry.header = strpart(l:entry.header, 2*l:local.level)
    endfor
    let l:depth += l:entries[0].level
  endif

  return filter(l:entries, 'v:val.level <= l:depth')
endfunction

" }}}1
function! wiki#page#get_anchors(...) abort " {{{1
  let l:filename = s:get_anchors_argument(a:000)
  if !filereadable(l:filename) | return [] | endif

  let anchor_level = ['', '', '', '', '', '', '']
  let anchors = []
  let current_section = ''
  let preblock = 0
  for line in readfile(l:filename)
    " Ignore fenced code blocks
    if line =~# '^\s*```'
      let l:preblock += 1
    endif
    if l:preblock % 2 | continue | endif

    " Parse headers
    let h_match = matchlist(line, wiki#rx#header_items())
    if !empty(h_match)
      let lvl = len(h_match[1]) - 1
      let anchor_level[lvl] = h_match[2]

      let current_section = '#' . join(anchor_level[:lvl], '#')
      call add(anchors, current_section)

      continue
    endif

    " Parse bolded text (there can be several in one line)
    let cnt = 0
    while 1
      let cnt += 1
      let text = matchstr(line, wiki#rx#bold(), 0, cnt)
      if empty(text) | break | endif

      call add(anchors, current_section . '#' . text[1:-2])
    endwhile
  endfor

  return anchors
endfunction

" }}}1
function! wiki#page#print(line1, line2) abort " {{{1
  let l:lines = getline(a:line1, a:line2)

  let l:wiki_link_rx = '\[\[#\?\([^\\|\]]\{-}\)\]\]'
  call map(l:lines, 'substitute(v:val, l:wiki_link_rx, ''\1'', ''g'')')

  let l:wiki_link_text_rx = '\[\[[^\]]\{-}|\([^\]]\{-}\)\]\]'
  call map(l:lines, 'substitute(v:val, l:wiki_link_text_rx, ''\1'', ''g'')')

  let l:tmp_wiki = tempname()
  let l:tmp_pdf = l:tmp_wiki . '.pdf'
  call writefile(l:lines, l:tmp_wiki)
  call system(['pandoc', '-f', 'gfm', '-o', l:tmp_pdf, l:tmp_wiki])
  call delete(l:tmp_wiki)

  echohl ModeMsg
  let l:reply = input('View file [y/N]? ')
  echohl None
  echon "\n"
  if l:reply =~# '^y'
    call system(g:wiki_pdf_viewer . ' ' . l:tmp_pdf)
  endif

  echohl ModeMsg
  let l:reply = input('Print file [y/N]? ')
  echohl None
  echon "\n"
  if l:reply =~# '^y'
    call system('lp ' . l:tmp_pdf)
  endif

  echohl ModeMsg
  let l:reply = input('Export file [y/N]? ')
  echohl None
  echon "\n"
  if l:reply =~# '^y'
    let l:newname = expand(input('File name: '))
    if l:newname[0] !=# '/'
      let l:newname = expand('~/') . l:newname
    endif
    call rename(l:tmp_pdf, l:newname)
  else
    call delete(l:tmp_pdf)
  endif
endfunction

" }}}1

function! s:rename_update_links(old, new) abort " {{{1
  let l:pattern  = '\v\[\[\/?\zs' . a:old . '\ze%(#.*)?%(\|.*)?\]\]'
  let l:pattern .= '|\[.*\]\[\zs' . a:old . '\ze%(#.*)?\]'
  let l:pattern .= '|\[.*\]\(\/?\zs' . a:old . '\ze%(#.*)?\)'
  let l:pattern .= '|\[\zs' . a:old . '\ze%(#.*)?\]\[\]'

  let l:num_files = 0
  let l:num_links = 0

  for l:file in glob(b:wiki.root . '/**/*.' . b:wiki.extension, 0, 1)
    let l:updates = 0
    let l:lines = []
    for l:line in readfile(l:file)
      if match(l:line, l:pattern) != -1
        let l:updates = 1
        let l:num_links += 1
        call add(l:lines, substitute(l:line, l:pattern, a:new, 'g'))
      else
        call add(l:lines, l:line)
      endif
    endfor

    if l:updates
      echom 'Updating links in: ' . fnamemodify(l:file, ':t')
      call rename(l:file, l:file . '#tmp')
      call writefile(l:lines, l:file)
      call delete(l:file . '#tmp')
      let l:num_files += 1
    endif
  endfor
  echom printf('Updated %d links in %d files', l:num_links, l:num_files)
endfunction

" }}}1

function! s:get_anchors_argument(input) abort " {{{1
  let l:current = expand('%:p')
  let l:arg = get(a:input, 0, '')

  if empty(l:arg)
    return l:current
  endif

  if type(l:arg) == type({})
    return get(l:arg, 'path', l:current)
  endif

  if type(l:arg) != type('')
    return expand('%:p')
  endif

  if filereadable(l:arg)
    return l:arg
  else
    return get(wiki#url#parse(l:arg), 'path', l:current)
  endif
endfunction

" }}}1
