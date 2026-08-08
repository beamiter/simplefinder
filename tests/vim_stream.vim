" Streamed grep results.
"
" The wire format carried a `done` field from the very first version and
" nothing ever set it to false: every request produced exactly one event, so
" on a cold walk the panel said `searching…` with an empty result area until
" the last file had been read.  Results now arrive in batches, and the panel
" has to handle that without lying about its state or moving rows out from
" under the cursor: a batch is a refined *snapshot*, so a match found late can
" sort in above the row the user is on and shift every index below it.  The
" viewport is a second thing to hold still — restoring the selected index while
" scrolling back to the top repaints the whole panel somewhere else, which on a
" real walk happens every 80ms while the user is reading.
"
" tests/fake_stream_daemon.py plays out a fixed batch sequence one batch at a
" time, gated on files this script creates, so each assertion runs against a
" known panel state rather than a race.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim_stream.vim

set nocompatible
set nomore
" The viewport assertions below count result rows, so pin the geometry rather
" than inherit whatever the terminal happens to be: 24 lines leaves the panel
" 22 rows, 18 of which show results (title, input, separator, help take four).
set lines=24

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

" Which panel line the marked row sits on, i.e. where the eye finds it.
function! s:CursorBufline() abort
  let l:lnum = 3
  for l:line in getbufline(bufnr('SimpleFinder'), 4, '$')
    let l:lnum += 1
    if l:line =~# '^▸'
      return l:lnum
    endif
  endfor
  return -1
endfunction

" The file named on the first result row: the top of the viewport.
function! s:TopFile() abort
  return matchstr(get(getbufline(bufnr('SimpleFinder'), 4, 4), 0, ''), '\f\+\.txt')
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

" The very first search of the session, with the daemon not yet started, has to
" stream too.  EnsureBackend() only *starts* the process: the ping is on the
" wire and the pong is not back, so HasCap('stream') was false and the request
" went out asking for a single reply -- on the one search guaranteed to be slow,
" because nothing is cached yet.  :SimpleFinderGrep, GrepWord and GrepVisual are
" one-shot, so nothing re-sent them afterwards either.  A request raised before
" the handshake now waits for it.
SimpleFinderIGrep needle

" First paint: results are on screen while the search is still running. Before
" streaming, this state did not exist -- the panel was empty until the end.
call s:Release(1, {-> s:Panel() =~# 'b\.txt'}, 'the first batch paints')
call assert_equal(4, simplefinder#core#Protocol(), 'protocol v4 is negotiated')
call assert_true(simplefinder#core#HasCap('stream'), 'the stream capability is advertised')
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

" A result set taller than the panel: following the cursor by identity keeps the
" right row selected, but the viewport must stay put too, or every batch drags
" the panel back to the top while the user is reading it.
SimpleFinderIGrep viewport
call s:Release(4, {-> s:Panel() =~# 'f00\.txt'}, 'the first viewport batch paints')
call assert_equal('f00.txt', s:TopFile(), 'a new result set starts at the top')

" Scroll past the bottom edge, then back up, so the selection ends up in the
" middle of the viewport rather than pinned to either edge -- 18 result rows,
" so item 25 leaves the viewport at offset 8 and item 15 sits on panel line 11.
for s:n in range(25)
  call feedkeys("\<C-j>", 'xt')
endfor
for s:n in range(10)
  call feedkeys("\<C-k>", 'xt')
endfor
call assert_match('f15\.txt', s:CursorRow(), 'the cursor is on the 16th result')
call assert_equal('f08.txt', s:TopFile(), 'the viewport is scrolled off the top')
call assert_equal(11, s:CursorBufline(), 'the selection sits mid-viewport')

" Batch 2 inserts a00.txt above everything, so every index shifts by one.
call s:Release(5, {-> s:Panel() !~# 'searching'}, 'the refining viewport batch paints')
call assert_match('f15\.txt', s:CursorRow(), 'the selection survives the batch')
call assert_equal('f08.txt', s:TopFile(),
      \ 'a partial repaint must not scroll the panel back to the top')
call assert_equal(11, s:CursorBufline(),
      \ 'the selected row keeps its place in the viewport')
call assert_match('41 results', s:Panel(), 'the final viewport batch is applied in full')

" A daemon that predates streaming must still be driven single-shot: waiting
" for the handshake is what makes that decision, so it has to survive a restart
" onto a different build as well as a cold start.  The search below is issued
" while the new process is still handshaking.
let $FAKE_NO_STREAM = 1
SimpleFinderRestart
call s:WaitFor({-> !simplefinder#core#IsRunning()}, 'the streaming daemon exits')
" The search itself starts the replacement, so it is again issued while the
" handshake is in flight.
SimpleFinderIGrep needle
call s:WaitFor({-> s:Panel() !~# 'searching'}, 'the un-negotiated daemon answers')
call assert_false(simplefinder#core#HasCap('stream'),
      \ 'the restarted daemon advertises no streaming')
call assert_match('0 results', s:Panel(),
      \ 'a daemon without the stream capability takes the single-reply path')

call simplefinder#Stop()
for s:n in range(1, 5)
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
