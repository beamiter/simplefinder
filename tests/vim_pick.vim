" The public picker API, the sources built on it, and the <Plug> targets.
"
" simplefinder#Pick() is the entry point a user or another plugin can add a
" source through; the marks, jumplist and quickfix sources are written against
" it rather than beside it, so if the API rots they rot with it.  A row that
" carries a location needs no source-specific code to be opened, previewed or
" exported -- these assertions are what says so.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim_pick.vim

set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)
call delete(s:root .. '/tests/pick-errors.log')

let g:simplefinder_preview = 0
let g:simplefinder_close_on_select = 1
runtime plugin/simplefinder.vim

function! s:Panel() abort
  let l:buf = bufnr('SimpleFinder')
  return l:buf > 0 ? join(getbufline(l:buf, 1, '$'), "\n") : ''
endfunction

function! s:Visible() abort
  for l:win in getwininfo()
    if bufname(l:win.bufnr) ==# 'SimpleFinder'
      return 1
    endif
  endfor
  return 0
endfunction

let s:file = tempname() .. '.txt'
call writefile(['alpha line', 'bravo line', 'charlie line', 'delta line'], s:file)
execute 'edit! ' .. fnameescape(s:file)
let s:bufnr = bufnr('%')

" ------------------------------------------------------------- <Plug> maps ---

for s:name in ['files', 'gitfiles', 'grep', 'igrep', 'grep-word', 'buffers',
      \ 'recent', 'lines', 'help', 'symbols', 'marks', 'jumps', 'quickfix',
      \ 'loclist', 'resume']
  call assert_true(!empty(maparg('<Plug>(simplefinder-' .. s:name .. ')', 'n')),
        \ '<Plug>(simplefinder-' .. s:name .. ') is defined')
endfor
call assert_true(!empty(maparg('<Plug>(simplefinder-grep-visual)', 'x')),
      \ 'the Visual-mode <Plug> target is still there')

" ------------------------------------------------------------- Pick() API ---

let g:pick_accepted = []
function! PickAccept(item, openmode) abort
  call add(g:pick_accepted, [a:item.display, a:openmode])
endfunction

call simplefinder#Pick({
      \ 'title': 'Colours',
      \ 'items': [{'display': 'crimson'}, {'display': 'cobalt'}, {'display': 'ochre'}],
      \ 'Accept': function('PickAccept'),
      \ })
call assert_true(s:Visible(), 'Pick() opens the panel')
call assert_match('Colours', s:Panel(), 'the picker title is the panel title')
call assert_match('crimson', s:Panel(), 'the rows are drawn')

" Typing narrows through the same fuzzy filter every local source uses.
call feedkeys('ochr', 'xt')
sleep 100m
call assert_match('ochre', s:Panel(), 'the query narrows a picker')
call assert_notmatch('crimson', s:Panel(), 'and drops what does not match')

call feedkeys("\<CR>", 'xt')
call assert_equal([['ochre', 'edit']], g:pick_accepted,
      \ 'Accept receives the chosen item and how it was opened')
call assert_false(s:Visible(), 'the panel closes on select')

" A picker without an Accept jumps to the location its rows carry -- no
" source-specific code involved.
execute 'edit! ' .. fnameescape(s:file)
call simplefinder#Pick({
      \ 'title': 'Places',
      \ 'items': [{'display': 'third', 'bufnr': s:bufnr, 'lnum': 3, 'col': 1}],
      \ })
call feedkeys("\<CR>", 'xt')
call assert_equal(3, line('.'), 'a location row opens at its line')

" Rows with neither display nor location still render: `text` and `path` are
" the obvious fallbacks, and nothing throws when <CR> has nowhere to go.
call simplefinder#Pick({'items': [{'text': 'from text'}, {'path': '/tmp/from-path'}]})
call assert_match('from text', s:Panel(), 'display falls back to text')
call assert_match('from-path', s:Panel(), 'and then to path')
call feedkeys("\<CR>", 'xt')

" A malformed spec is reported, not thrown.
call simplefinder#Pick({'title': 'Broken', 'items': 'not a list'})
call assert_notmatch('Broken', s:Panel(), 'a malformed spec does not open a panel')

" ----------------------------------------------------------------- marks ---

execute 'edit! ' .. fnameescape(s:file)
normal! 2G
normal! ma
normal! 4G
normal! mB
SimpleFinderMarks
call assert_match('Marks', s:Panel(), 'the marks panel opens')
call assert_match('a .*:2', s:Panel(), 'a buffer-local mark is listed with its line')
call assert_match('B .*:4', s:Panel(), 'a global mark is listed too')
call assert_match('bravo line', s:Panel(), 'the line the mark points at is shown')

" Cursor bookkeeping marks ('. '^ '" '< '>) are not places anyone set.
call assert_notmatch("^ *[.^\"<>] ", s:Panel(), 'automatic marks are left out')

normal! 1G
call feedkeys("\<CR>", 'xt')
call assert_equal(2, line('.'), 'opening a mark jumps to it')

" A mark's file name is a name, not an expression.  Marks() ran it through
" expand() -- a wildcard, environment-variable, %/#-special and backtick
" expander -- so a mark set in `lit$HOME.txt` was listed, previewed and
" exported to quickfix under `lit/home/you.txt`, a path nothing can open.
let s:magic = fnamemodify(s:file, ':h') .. '/lit$HOME.txt'
call writefile(['one', 'marked line', 'three'], s:magic)
call assert_notequal(s:magic, expand(s:magic),
      \ 'the fixture is a name expand() really does mangle')
execute 'edit! ' .. fnameescape(s:magic)
normal! 2G
normal! mC
let s:magic_bufnr = bufnr('%')
execute 'edit! ' .. fnameescape(s:file)
" Marks on a file with no loaded buffer are the normal cross-session case, and
" the one where only the name is left to go on.
execute 'bdelete! ' .. s:magic_bufnr
SimpleFinderMarks
call assert_match('C .*lit\$HOME\.txt:2', s:Panel(),
      \ 'a mark is listed under the file name it was set in')
call assert_notmatch('lit/', s:Panel(),
      \ 'and that name is not run through an environment-variable expander')
call feedkeys("\<Esc>", 'xt')
call delete(s:magic)

" ------------------------------------------------------------------ jumps ---

execute 'edit! ' .. fnameescape(s:file)
normal! 1G
normal! 4G
normal! 2G
SimpleFinderJumps
call assert_match('Jumps', s:Panel(), 'the jumps panel opens')
call assert_match('line', s:Panel(), 'jump rows carry the line they point at')
call feedkeys("\<Esc>", 'xt')

" --------------------------------------------------------------- quickfix ---

call setqflist([], ' ', {'title': 'fixture', 'items': [
      \ {'bufnr': s:bufnr, 'lnum': 3, 'col': 1, 'text': 'charlie hit'},
      \ {'bufnr': s:bufnr, 'lnum': 4, 'col': 1, 'text': 'delta hit'},
      \ ]})
execute 'edit! ' .. fnameescape(s:file)
normal! 1G
SimpleFinderQuickfix
call assert_match('Quickfix: fixture', s:Panel(),
      \ 'the quickfix list title is carried into the panel')
call assert_match('charlie hit', s:Panel(), 'quickfix entries are rows')
call feedkeys('delta', 'xt')
sleep 100m
call feedkeys("\<CR>", 'xt')
call assert_equal(4, line('.'), 'choosing a quickfix row jumps to it')

" A location list is the same source pointed at the window's own list.
call setloclist(win_getid(), [], ' ', {'title': 'locs', 'items': [
      \ {'bufnr': s:bufnr, 'lnum': 2, 'col': 1, 'text': 'bravo loc'}]})
SimpleFinderLoclist
call assert_match('Location list: locs', s:Panel(), 'the location list opens')
call assert_match('bravo loc', s:Panel(), 'its entries are rows')
call feedkeys("\<Esc>", 'xt')

" ----------------------------------------------------------------- resume ---

SimpleFinderMarks
call feedkeys("\<Esc>", 'xt')
SimpleFinderResume
call assert_match('Marks', s:Panel(), 'resume re-opens a picker source')
call feedkeys("\<Esc>", 'xt')

call delete(s:file)

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/pick-errors.log')
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit
endif
qall!
