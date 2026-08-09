" The preview popup and tabpages.
"
" Making PanelRender() tabpage-agnostic was right -- a panel sitting in another
" tab must still receive the results that arrive while you are elsewhere -- but
" it dragged the preview along with it, and a popup is not tabpage-agnostic at
" all: popup_create() puts it in the *current* tab, and the geometry it is given
" came from win_screenpos(win_id2win(panel)), where win_id2win() answers 0 from
" another tab and win_screenpos(0) means "the current window".  So a streamed
" batch arriving while the user was editing in another tab drew a preview of a
" grep result over the buffer they were looking at, in a tab with no panel in
" it, sized to the wrong window.
"
" tests/fake_stream_daemon.py hands out its batches one at a time, gated on
" files this script creates, so the batch lands at a moment this test picks:
" with the panel in tab 1 and the cursor in tab 2.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim_tabs.vim

set nocompatible
set nomore
" The preview fills the columns beside the panel and gives up below 30 of them;
" a silent-ex Vim reports an 80x24 screen, so the room comes out of the panel.
set lines=24
let g:simplefinder_panel_width = 30

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)
call delete(s:root .. '/tests/tabs-errors.log')

" A skip has to say so: a silent `qall!` is indistinguishable from a pass.
function! s:Skip(why) abort
  try
    call writefile(['SKIP tests/vim_tabs.vim: ' .. a:why], '/dev/stderr')
  catch
  endtry
  qall!
endfunction

if !has('popupwin')
  call s:Skip('this Vim has no popup windows')
endif

let s:fake = s:root .. '/tests/fake_stream_daemon.py'
if !executable(s:fake)
  " CI checkouts do not always preserve the mode bit.
  call setfperm(s:fake, 'rwxr-xr-x')
endif
if !executable(s:fake)
  call s:Skip('tests/fake_stream_daemon.py is not executable')
endif

let s:gate = tempname()
let $FAKE_GATE = s:gate
let g:simplefinder_daemon_path = s:fake
let g:simplefinder_preview = 1
let g:simplefinder_close_on_select = 0
runtime plugin/simplefinder.vim

function! s:Panel() abort
  let l:buf = bufnr('SimpleFinder')
  return l:buf > 0 ? join(getbufline(l:buf, 1, '$'), "\n") : ''
endfunction

" The preview is the only popup this test ever opens.
function! s:PreviewId() abort
  for l:id in popup_list()
    if bufname(winbufnr(l:id)) !=# 'SimpleFinder'
      return l:id
    endif
  endfor
  return 0
endfunction

function! s:WaitFor(Cond, label) abort
  for l:attempt in range(300)
    if call(a:Cond, [])
      return 1
    endif
    sleep 10m
  endfor
  call assert_true(0, 'timeout: ' .. a:label)
  return 0
endfunction

" The daemon answers with bare file names, so the results have to resolve
" against a project root holding real files for the preview to have anything
" to show.
let s:dir = tempname()
call mkdir(s:dir .. '/.git', 'p')
for s:name in ['a', 'b', 'c', 'd']
  call writefile([s:name .. ' line one', s:name .. ' line two'],
        \ s:dir .. '/' .. s:name .. '.txt')
endfor
execute 'cd ' .. fnameescape(s:dir)
call simplefinder#ProjectRoot(s:dir)

" ------------------------------------------- a batch arriving from another tab ---

SimpleFinderIGrep needle
let s:panel_winid = bufwinid('SimpleFinder')
call assert_true(s:panel_winid > 0, 'the panel window is open in this tab')

" Leave the panel where it is and go and edit something else, in another tab
" with a split, so "the current window" there is neither the panel nor even in
" the same column as it.
wincmd p
tabnew
vsplit
wincmd l
call assert_equal(2, tabpagenr(), 'the user is editing in the second tab')
call assert_equal(0, win_id2win(s:panel_winid),
      \ 'the panel is not reachable by the tabpage-local win_id2win()')
call assert_equal(0, s:PreviewId(), 'nothing is drawn before the batch lands')

call writefile([], printf('%s.%d', s:gate, 1))
call s:WaitFor({-> s:Panel() =~# 'b\.txt'}, 'the batch reaches the panel buffer')

" The panel itself must still repaint -- that is the whole point of rendering
" across tabpages.
call assert_match('2 results · searching…', s:Panel(),
      \ 'a panel in another tab still receives the results')
" ...and the preview must not, because there is nowhere in this tab it could
" honestly go.
call assert_equal(0, s:PreviewId(),
      \ 'no preview is drawn into the tab the user is editing in')

" ------------------------------------------------- back where the panel is ---

tabclose
call assert_equal(1, tabpagenr(), 'back in the tab holding the panel')
call win_gotoid(s:panel_winid)
call feedkeys("\<C-j>", 'xt')
sleep 100m
let s:preview = s:PreviewId()
call assert_true(s:preview > 0, 'the preview comes back with the panel')
call assert_equal(1, popup_getpos(s:preview).visible, 'and it is visible')

" Its geometry is the panel's, not whatever window happened to be current
" somewhere else: the preview fills the columns to the left of the panel.
let s:wincol = getwininfo(s:panel_winid)[0].wincol
call assert_equal(s:wincol - 4, popup_getpos(s:preview).core_width,
      \ 'the preview is sized from the panel window')
call assert_match('line one', join(getbufline(winbufnr(s:preview), 1, '$'), "\n"),
      \ 'and it shows the selected result')

call simplefinder#Stop()
for s:n in range(1, 5)
  call delete(printf('%s.%d', s:gate, s:n))
endfor
execute 'cd ' .. fnameescape(s:root)
call delete(s:dir, 'rf')

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/tabs-errors.log')
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit
endif
qall!
