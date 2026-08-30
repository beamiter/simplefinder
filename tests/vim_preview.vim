" The preview popup.
"
" It used to read the file from disk on every cursor move -- from byte 0 down
" to the line it wanted, so a result deep in a large file re-parsed the whole
" prefix per keypress -- showed on-disk text for a buffer with unsaved edits
" (in `lines` mode the item text comes from getline(), so the highlighted
" preview line did not contain the match), could not be scrolled, had no
" syntax highlighting, and ran the path through expand(), which reads '#' and
" '%' in a file name as Vim specials.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim_preview.vim

set nocompatible
set nomore
" The preview fills the columns beside the panel and gives up below 30 of them.
" A silent-ex Vim reports the default 80x24 screen whatever 'columns' is set
" to, so the room has to come out of the panel instead.
let g:simplefinder_panel_width = 30

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)
call delete(s:root .. '/tests/preview-errors.log')

" A skip has to say so: a silent `qall!` is indistinguishable from a pass.
function! s:Skip(why) abort
  try
    call writefile(['SKIP tests/vim_preview.vim: ' .. a:why], '/dev/stderr')
  catch
  endtry
  qall!
endfunction

if !has('popupwin')
  call s:Skip('this Vim has no popup windows')
endif

let g:simplefinder_preview = 1
let g:simplefinder_close_on_select = 0
syntax enable
filetype plugin indent on
runtime plugin/simplefinder.vim

" The preview is the only popup this test ever opens.
function! s:PreviewId() abort
  for l:id in popup_list()
    if bufname(winbufnr(l:id)) !=# 'SimpleFinder'
      return l:id
    endif
  endfor
  return 0
endfunction

function! s:PreviewLines() abort
  let l:id = s:PreviewId()
  return l:id <= 0 ? [] : getbufline(winbufnr(l:id), 1, '$')
endfunction

let s:dir = tempname()
call mkdir(s:dir, 'p')

" ------------------------------------------------- unsaved buffer content ---

" 60 numbered lines, so the preview shows a window into the middle of it.
let s:file = s:dir .. '/sample.rs'
call writefile(map(range(1, 60), {_, n -> printf('fn disk_%02d() {}', n)}), s:file)
execute 'edit! ' .. fnameescape(s:file)

" Unsaved edit: line 30 says something the file on disk does not.
call setline(30, 'fn unsaved_marker() {}')
SimpleFinderLines
call feedkeys('unsaved_marker', 'xt')
sleep 150m
call assert_match('unsaved_marker', join(s:PreviewLines(), "\n"),
      \ 'a modified buffer previews what is in the buffer, not what is on disk')

" The filetype of a loaded buffer is the authority on how to highlight it.
call assert_equal('rust', getwinvar(s:PreviewId(), '&syntax'),
      \ 'the preview is highlighted as the previewed file')

" ------------------------------------------------------------- scrolling ---

let s:before = s:PreviewLines()
call feedkeys("\<PageDown>", 'xt')
let s:after = s:PreviewLines()
call assert_notequal(s:before, s:after, '<PageDown> scrolls the preview')
call feedkeys("\<PageUp>", 'xt')
call assert_equal(s:before, s:PreviewLines(), '<PageUp> scrolls back')

" Scrolling is relative to the selected match, so a new selection starts over.
call feedkeys("\<C-u>", 'xt')
sleep 150m
call feedkeys("\<PageDown>", 'xt')
call assert_notmatch('disk_01', join(s:PreviewLines(), "\n"),
      \ 'the preview is scrolled away from the top')
call feedkeys("\<C-j>", 'xt')
call assert_match('^fn disk_01', get(s:PreviewLines(), 0, ''),
      \ 'selecting another result resets the preview scroll')

" The bottom of the file is the end of the scroll: pressing on must not empty
" the popup.
for s:n in range(20)
  call feedkeys("\<PageDown>", 'xt')
endfor
call assert_match('disk_60', join(s:PreviewLines(), "\n"),
      \ 'scrolling past the end stops at the last line')
call feedkeys("\<Esc>", 'xt')

" ------------------------------------------------- names Vim treats as magic ---

" The path is resolved with fnamemodify(':p'), which handles '~' and relative
" names and nothing else.  expand() is a wildcard, environment-variable and
" %/#-special expander aimed at a file name; a name is not an expression.
"
" '$' is the character that discriminates.  expand() rewrites 'lit$HOME.txt'
" into 'lit/home/you.txt', a path nothing can read, so the preview went blank.
" '#' and '%' are file specials on a command line, not mid-string in expand(),
" so a fixture carrying only those passes against the old code too: they stay
" in the name, but they are not what proves anything.
"
" The name has to be previewed from disk for this to prove anything: a result
" carrying a live buffer number is read out of that buffer and never touches
" the path at all, so the buffer is wiped before the picker is opened.
let s:odd = s:dir .. '/lit$HOME od#d %file.txt'
call writefile(['odd name content'], s:odd)
call assert_notequal(s:odd, expand(s:odd),
      \ 'the fixture is a name expand() really does mangle')
execute 'edit! ' .. fnameescape(s:odd)
let s:odd_bufnr = bufnr('%')
execute 'edit! ' .. fnameescape(s:file)
execute 'bwipeout! ' .. s:odd_bufnr
SimpleFinderRecent
call feedkeys('lit', 'xt')
sleep 150m
call assert_match('odd name content', join(s:PreviewLines(), "\n"),
      \ 'a file name holding $, # or % is previewed as itself')
call feedkeys("\<Esc>", 'xt')

" ------------------------------------------------------------- disk reads ---

" A file that is not loaded in a buffer is read from disk, highlighted from its
" extension, and read once however many times it is previewed.
let s:cold = s:dir .. '/cold.py'
call writefile(map(range(1, 40), {_, n -> printf('def cold_%02d(): pass', n)}), s:cold)
execute 'edit! ' .. fnameescape(s:cold)
let s:cold_bufnr = bufnr('%')
execute 'edit! ' .. fnameescape(s:file)
execute 'bwipeout! ' .. s:cold_bufnr
SimpleFinderRecent
call feedkeys('cold.py', 'xt')
sleep 150m
call assert_match('cold_01', join(s:PreviewLines(), "\n"),
      \ 'an unopened file is previewed from disk')
call assert_equal('python', getwinvar(s:PreviewId(), '&syntax'),
      \ 'an unopened file is highlighted from its extension')
call feedkeys("\<Esc>", 'xt')

call delete(s:dir, 'rf')

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/preview-errors.log')
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit
endif
qall!
