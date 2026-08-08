" Visual-mode grep must read the *live* selection.
"
" README.md and the help both teach `xnoremap <leader>fg
" <Cmd>SimpleFinderGrepVisual<CR>`, and a <Cmd> mapping deliberately leaves the
" '< and '> marks describing the *previous* selection (:help <Cmd>).  Reading
" the marks therefore grepped the wrong text on every invocation, and on the
" first selection of a session they are [0, 0, 0, 0], getline(0, 0) is empty
" and the command did nothing at all.  The live region has to come from `v`
" (the anchor) and `.` (the cursor) instead, while the `:'<,'>` command form
" keeps reading the marks because there no Visual mode is active any more.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim_visual.vim

set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)
call delete(s:root .. '/tests/visual-errors.log')

let s:daemon = s:root .. '/target/debug/simplefinder-daemon'
if !executable(s:daemon)
  let s:daemon = s:root .. '/lib/simplefinder-daemon'
endif
let g:simplefinder_daemon_path = s:daemon
let g:simplefinder_preview = 0
let g:simplefinder_close_on_select = 0
runtime plugin/simplefinder.vim

xnoremap <F5> <Cmd>SimpleFinderGrepVisual<CR>

" The query is the second panel row: ' > <query><U+2581> [flags]'.
function! s:Query() abort
  let l:buf = bufnr('SimpleFinder')
  if l:buf <= 0
    return ''
  endif
  let l:line = get(getbufline(l:buf, 2), 0, '')
  return matchstr(l:line, '^ > \zs.\{-}\ze\%u2581')
endfunction

let s:file = tempname()
call writefile(['alpha bravo', 'charlie delta', 'echo foxtrot'], s:file)
execute 'edit! ' .. fnameescape(s:file)
let s:src = win_getid()

" Run `keys` as a Visual selection in the source window and report the query
" the panel ended up searching for.  The trailing <Esc> unwinds whatever mode
" the <Cmd> mapping left behind and closes the panel, so each case starts from
" the same place.
function! s:GrepSelection(keys) abort
  call win_gotoid(s:src)
  call feedkeys(a:keys .. "\<F5>\<Esc>", 'xt')
  return s:Query()
endfunction

" A single charwise selection, and the first one of the session: with the
" marks this searched for nothing at all.
call assert_equal('bravo', s:GrepSelection('1G0wv$'), 'first charwise selection')

" The regression proper: the second selection used to search the first one.
call assert_equal('delta', s:GrepSelection('2G0wv$'), 'second charwise selection')

" Multi-line charwise joins the partial lines with a space, as before.
call assert_equal('bravo charlie', s:GrepSelection('1G0wvj'), 'multi-line charwise')

" Linewise takes whole lines whatever the columns say.
call assert_equal('echo foxtrot', s:GrepSelection('3G0wV'), 'linewise')

" Blockwise takes the same column range out of every line.
call assert_equal('alpha charl', s:GrepSelection("1G0\<C-v>j4l"), 'blockwise')

" <Plug>(simplefinder-grep-visual) is the supported mapping target.
call assert_true(!empty(maparg('<Plug>(simplefinder-grep-visual)', 'x')),
      \ 'the <Plug> mapping is defined for Visual mode')
xmap <F6> <Plug>(simplefinder-grep-visual)
call win_gotoid(s:src)
call feedkeys("2G0wv$\<F6>\<Esc>", 'xt')
call assert_equal('delta', s:Query(), '<Plug> mapping greps the live selection')

" The :'<,'>SimpleFinderGrepVisual form has no live Visual mode to read, so it
" keeps using the marks and must keep working.
call win_gotoid(s:src)
call feedkeys("1G0v4l\<Esc>", 'xt')
execute "'<,'>SimpleFinderGrepVisual"
call assert_equal('alpha', s:Query(), "the :'<,'> command form still uses the marks")

call simplefinder#Stop()
call delete(s:file)

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/visual-errors.log')
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit
endif
qall!
