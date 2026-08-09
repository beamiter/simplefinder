" :SimpleFinderStop and a search still waiting for the handshake.
"
" A request raised before the pong comes back is held and re-dispatched once
" capabilities are known, on a 2 second timer.  Nothing cancelled that timer,
" and re-dispatching runs through EnsureBackend(), which *starts* the daemon --
" so stopping the daemon while a search was held did not stop anything: two
" seconds later the held request spawned a fresh process, with nothing on
" screen to explain where it came from.  :SimpleFinderStop is an instruction,
" not a pause.
"
" tests/fake_slow_daemon.py never answers the ping until this script says so,
" which is the whole window the bug lives in, and logs a line per process so
" "still the one daemon" can be told from "a second one was started".
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim_negotiate.vim

set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)
call delete(s:root .. '/tests/negotiate-errors.log')

" A skip has to say so: a silent `qall!` is indistinguishable from a pass.
function! s:Skip(why) abort
  try
    call writefile(['SKIP tests/vim_negotiate.vim: ' .. a:why], '/dev/stderr')
  catch
  endtry
  qall!
endfunction

let s:fake = s:root .. '/tests/fake_slow_daemon.py'
if !executable(s:fake)
  " CI checkouts do not always preserve the mode bit.
  call setfperm(s:fake, 'rwxr-xr-x')
endif
if !executable(s:fake)
  call s:Skip('tests/fake_slow_daemon.py is not executable')
endif

let s:spawns = tempname()
let s:pong_gate = tempname()
let $FAKE_SPAWN_LOG = s:spawns
let $FAKE_PONG_GATE = s:pong_gate
let g:simplefinder_daemon_path = s:fake
let g:simplefinder_preview = 0
let g:simplefinder_close_on_select = 0
runtime plugin/simplefinder.vim

function! s:Panel() abort
  let l:buf = bufnr('SimpleFinder')
  return l:buf > 0 ? join(getbufline(l:buf, 1, '$'), "\n") : ''
endfunction

function! s:Spawns() abort
  return filereadable(s:spawns) ? len(readfile(s:spawns)) : 0
endfunction

function! s:WaitFor(Cond, label) abort
  for l:attempt in range(500)
    if call(a:Cond, [])
      return 1
    endif
    sleep 10m
  endfor
  call assert_true(0, 'timeout: ' .. a:label)
  return 0
endfunction

" Real time has to pass for the negotiation timer to fire, and `sleep` is what
" lets it: the budget is 2 seconds, so wait past it with room to spare.
function! s:PastTheBudget() abort
  for l:tick in range(35)
    sleep 100m
  endfor
endfunction

" ------------------------------------------------- a search left in the air ---

SimpleFinderIGrep needle
call s:WaitFor({-> simplefinder#core#IsRunning()}, 'the daemon starts')
call s:WaitFor({-> s:Spawns() == 1}, 'exactly one daemon is started')
call assert_false(simplefinder#core#Ready(),
      \ 'the handshake has not completed')
call assert_match('searching…', s:Panel(),
      \ 'the search is held until the handshake completes')

" ------------------------------------------------------------------- stop ---

call simplefinder#Stop()
" job_stop() asks; the process still has to go away.
call s:WaitFor({-> !simplefinder#core#IsRunning()}, 'the daemon stops')
call assert_notmatch('searching…', s:Panel(),
      \ 'a held search does not leave the panel spinning after a stop')
call assert_match('backend stopped', s:Panel(),
      \ 'and the panel says why it gave up')

" The bug: the held request outlived the stop and re-dispatched itself through
" EnsureBackend() once the negotiation budget ran out.
call s:PastTheBudget()
call assert_false(simplefinder#core#IsRunning(),
      \ 'the daemon is still stopped once the negotiation budget expires')
call assert_equal(1, s:Spawns(),
      \ 'a stopped daemon is not restarted by a request the user never re-sent')

" ------------------------------------------------- and the plugin still works ---

" Stopping is not wedging: the next search the user asks for starts a daemon
" again, and this one answers the ping.
call writefile([], s:pong_gate)
SimpleFinderIGrep needle
call s:WaitFor({-> s:Panel() !~# 'searching'}, 'the next search completes')
call assert_true(simplefinder#core#HasCap('stream'),
      \ 'the replacement daemon negotiates normally')
call assert_match('0 results', s:Panel(), 'and its answer reaches the panel')
call assert_equal(2, s:Spawns(),
      \ 'the only other daemon is the one the user asked for')

call simplefinder#Stop()
call delete(s:spawns)
call delete(s:pong_gate)

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/negotiate-errors.log')
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit
endif
qall!
