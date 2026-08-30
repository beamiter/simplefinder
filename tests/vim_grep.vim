" A capped grep must be deterministic and must say how much it left out.
"
" Worker threads used to append into one shared Vec in walk-completion order
" and the drain truncated that unordered Vec *before* sorting, so the results
" a user saw for a common term were a scheduling-dependent subset: two
" identical queries disagreed, and <C-q> exported whichever subset that run
" produced.  The daemon now keeps the first `max` results of the fully sorted
" order and counts every match it saw, so the panel can report `20/192
" results` instead of an unfalsifiable `20+ results`.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim_grep.vim

set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)
call delete(s:root .. '/tests/grep-errors.log')

" A missing daemon has to say so, and has to fail.  `make check` builds it
" (Makefile) before running any of this, so its absence means the build stopped
" producing a daemon -- not an environment worth skipping -- and a bare `qall!`
" here made that indistinguishable from a pass.  `echoerr` is swallowed by the
" silent-ex Vim these suites run under, so the message goes to /dev/stderr, the
" way the SKIP in vim_tabs.vim does.
function! s:Fail(why) abort
  try
    call writefile(['FAIL tests/vim_grep.vim: ' .. a:why], '/dev/stderr')
  catch
  endtry
  cquit
endfunction

let s:daemon = s:root .. '/target/debug/simplefinder-daemon'
if !executable(s:daemon)
  let s:daemon = s:root .. '/lib/simplefinder-daemon'
endif
if !executable(s:daemon)
  call s:Fail('no simplefinder-daemon in target/debug or lib; build it with cargo build')
endif

let g:simplefinder_daemon_path = s:daemon
let g:simplefinder_preview = 0
let g:simplefinder_close_on_select = 0
let g:simplefinder_max_results = 20
runtime plugin/simplefinder.vim

" 24 files x 8 matching lines: comfortably more than one walk batch, and far
" more matches than the cap.
let s:project = tempname()
call mkdir(s:project, 'p')
call writefile([], s:project .. '/.git')
for s:n in range(24)
  let s:body = map(range(8), {_, l -> printf('needle %02d %d', s:n, l)})
  call writefile(s:body, printf('%s/file%02d.txt', s:project, s:n))
endfor
let g:simplefinder_root = s:project

function! s:Panel() abort
  return join(getbufline(bufnr('SimpleFinder'), 1, '$'), "\n")
endfunction

function! s:Wait() abort
  let l:tries = 0
  while l:tries < 200 && s:Panel() =~# 'searching'
    sleep 20m
    let l:tries += 1
  endwhile
endfunction

" Read the results the way the workflow this bug broke does: export the whole
" capped set to quickfix. The panel only renders as many rows as fit, so its
" text cannot tell us what <C-q> would have exported.
function! s:Exported() abort
  call s:Wait()
  call feedkeys("\<C-q>", 'xt')
  let l:items = map(getqflist(),
        \ {_, item -> bufname(item.bufnr) .. ':' .. item.lnum .. ':' .. item.text})
  cclose
  return l:items
endfunction

SimpleFinderIGrep needle
call s:Wait()

" The cap is reported against the real number of matches, not against itself.
call assert_match('20/192 results', s:Panel(), 'the panel reports the honest total')
call assert_notmatch('20+ results', s:Panel())

" The kept results are the *first* 20 of the sorted order, which is the only
" subset a user can reason about -- and the only one <C-q> can usefully export.
let s:first = s:Exported()
call assert_equal(20, len(s:first), 'the cap is honoured')
call assert_match('file00\.txt:1:', s:first[0], 'the first result leads the path order')
call assert_match('file02\.txt:4:', s:first[-1], 'results stop where the sorted order stops')

" Repeating the identical query must export the identical results.
for s:attempt in range(4)
  SimpleFinderIGrep needle
  call assert_equal(s:first, s:Exported(),
        \ 'a capped grep returns the same results on every run')
endfor

" The panel captures keystrokes with one mapping per printable ASCII character
" and nothing else, so a non-ASCII keystroke matched no mapping and was dropped
" without a word -- grepping a Chinese identifier from the panel was simply not
" possible. <C-f> hands the query to the command line, which accepts anything.
SimpleFinderIGrep needle
call s:Wait()
call feedkeys("\<C-f>\<C-u>中文 needle\<CR>", 'xt')
call assert_match('中文 needle', s:Panel(), 'a non-ASCII query reaches the panel')

" Every <C-f> here has to end in <CR>: input() falls through to stdin when the
" typeahead does not close it, and in -es mode that hangs the suite instead of
" failing it. Cancelling with <Esc> is therefore left untested on purpose.
call feedkeys("\<C-f>\<C-u>needle\<CR>", 'xt')
call s:Wait()
call assert_notmatch('中文', s:Panel(), 'the edited query replaces the old one')

" Results that arrive while you are in another tab still have to be drawn.
" PanelRender guarded on win_id2win(), which is tabpage-local and returns 0 for
" a perfectly live panel that merely sits in another tab, so the results were
" stored and never painted: coming back showed a stale `searching…` until the
" next keypress.
SimpleFinderIGrep needle
tabnew
call s:Wait()
call assert_notmatch('searching', s:Panel(), 'the panel is drawn from another tab')
call assert_match('20/192 results', s:Panel(),
      \ 'results arriving while the panel is off-tab reach the buffer')
tabclose

call simplefinder#Stop()
call delete(s:project, 'rf')

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/grep-errors.log')
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit
endif
qall!
