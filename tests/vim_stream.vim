" Streamed grep results.
"
" The wire format carried a `done` field from the very first version and
" nothing ever set it to false: every request produced exactly one event, so
" on a cold walk the panel said `searching…` with an empty result area until
" the last file had been read.  Results now arrive in batches, and the panel
" has to handle that without lying about its state or moving rows out from
" under the cursor: a batch is a refined *snapshot*, so a match found late can
" sort in above the row the user is on and shift every index below it.
"
" tests/fake_stream_daemon.py plays out a fixed batch sequence one batch at a
" time, gated on files this script creates, so each assertion runs against a
" known panel state rather than a race.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim_stream.vim

set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)
call delete(s:root .. '/tests/stream-errors.log')

let s:fake = s:root .. '/tests/fake_stream_daemon.py'
if !executable(s:fake)
  " CI checkouts do not always preserve the mode bit.
  call setfperm(s:fake, 'rwxr-xr-x')
endif
if !executable(s:fake)
  qall!
endif

let s:gate = tempname()
let $FAKE_GATE = s:gate
let g:simplefinder_daemon_path = s:fake
let g:simplefinder_preview = 0
let g:simplefinder_close_on_select = 0
runtime plugin/simplefinder.vim

function! s:Panel() abort
  return join(getbufline(bufnr('SimpleFinder'), 1, '$'), "\n")
endfunction

" The row the cursor is on is the one carrying the marker glyph.
function! s:CursorRow() abort
  for l:line in getbufline(bufnr('SimpleFinder'), 4, '$')
    if l:line =~# '^▸'
      return l:line
    endif
  endfor
  return ''
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

" Release batch N and wait for the panel to show it.
function! s:Release(index, Cond, label) abort
  call writefile([], printf('%s.%d', s:gate, a:index))
  return s:WaitFor(a:Cond, a:label)
endfunction

" A request sent before the handshake lands cannot know whether the daemon
" streams, so it must not ask for it -- and the daemon must answer it in one
" shot.  That is also the path an older daemon always takes.
SimpleFinderIGrep warmup
call s:WaitFor({-> s:Panel() !~# 'searching'}, 'the un-negotiated request gets one reply')
call assert_equal(4, simplefinder#core#Protocol(), 'protocol v4 is negotiated')
call assert_true(simplefinder#core#HasCap('stream'), 'the stream capability is advertised')

SimpleFinderIGrep needle

" First paint: results are on screen while the search is still running. Before
" streaming, this state did not exist -- the panel was empty until the end.
call s:Release(1, {-> s:Panel() =~# 'b\.txt'}, 'the first batch paints')
call assert_match('2 results · searching…', s:Panel(),
      \ 'a partial result says how much is on screen and that more is coming')

" Move onto the second row, then let a batch arrive that inserts a new first
" row. Following the cursor by index would silently move it to b.txt.
call feedkeys("\<C-j>", 'xt')
call assert_match('c\.txt', s:CursorRow(), 'the cursor is on the second row')
call s:Release(2, {-> s:Panel() =~# 'a\.txt'}, 'the refining batch paints')
call assert_match('3 results · searching…', s:Panel())
call assert_match('c\.txt', s:CursorRow(),
      \ 'a row inserted above the cursor must not move the cursor')

" Only the final batch ends the search, and only it carries the authoritative
" count. 4 of 12 with an inexact total renders as 4/12+.
call s:Release(3, {-> s:Panel() !~# 'searching'}, 'the final batch completes the search')
call assert_match('4/12+ results', s:Panel(),
      \ 'the final batch reports the authoritative, honestly-marked total')
call assert_match('d\.txt', s:Panel(), 'the final batch is applied in full')
call assert_match('c\.txt', s:CursorRow(), 'the cursor survives the final batch')

call simplefinder#Stop()
for s:n in range(1, 3)
  call delete(printf('%s.%d', s:gate, s:n))
endfor

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/stream-errors.log')
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit
endif
qall!
