" Grep asks to share the file finder's list of the tree.
"
" Interactive grep sends one request per keystroke and each one re-walked the
" whole project -- every .gitignore re-read, every directory stat-ed again --
" before a single file could be searched.  The daemon already keeps that list
" for the file finder, so grep asks for it with `file_cache`.
"
" The field is negotiated, and negotiation is the part that breaks silently:
" sent to a daemon that never heard of it, it is ignored and the plugin has no
" way to know; not sent to one that supports it, and the walk stays.  So assert
" on the request itself.  tests/fake_echo_daemon.py records every request it
" receives and advertises exactly the capabilities the test names.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim_cache.vim

set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)
call delete(s:root .. '/tests/cache-errors.log')

" A skip has to say so: a silent `qall!` is indistinguishable from a pass.
function! s:Skip(why) abort
  try
    call writefile(['SKIP tests/vim_cache.vim: ' .. a:why], '/dev/stderr')
  catch
  endtry
  qall!
endfunction

let s:fake = s:root .. '/tests/fake_echo_daemon.py'
if !executable(s:fake)
  " CI checkouts do not always preserve the mode bit.
  call setfperm(s:fake, 'rwxr-xr-x')
endif
if !executable(s:fake)
  call s:Skip('tests/fake_echo_daemon.py is not executable')
endif

let s:log = tempname()
let $FAKE_LOG = s:log
let g:simplefinder_daemon_path = s:fake
let g:simplefinder_preview = 0
let g:simplefinder_close_on_select = 0
runtime plugin/simplefinder.vim

function! s:Panel() abort
  return join(getbufline(bufnr('SimpleFinder'), 1, '$'), "\n")
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

" The last request of the given type the daemon received.
function! s:LastRequest(type) abort
  let l:found = {}
  for l:line in filereadable(s:log) ? readfile(s:log) : []
    try
      let l:req = json_decode(l:line)
    catch
      continue
    endtry
    if type(l:req) == v:t_dict && get(l:req, 'type', '') ==# a:type
      let l:found = l:req
    endif
  endfor
  return l:found
endfunction

" Re-handshake against a daemon advertising exactly `caps`, and clear the log
" so the next assertion cannot read a request from the previous round.
function! s:Restart(caps) abort
  call simplefinder#Stop()
  call s:WaitFor({-> !simplefinder#core#IsRunning()}, 'the daemon exits')
  let $FAKE_CAPS = a:caps
  call delete(s:log)
endfunction

" ── A daemon that advertises grep_cache is asked to use it ──
SimpleFinderIGrep needle
call s:WaitFor({-> !empty(s:LastRequest('grep'))}, 'the grep request is sent')
call s:WaitFor({-> s:Panel() !~# 'searching'}, 'the daemon answers')
call assert_true(simplefinder#core#HasCap('grep_cache'),
      \ 'the fake daemon advertises grep_cache')
call assert_equal(v:true, get(s:LastRequest('grep'), 'file_cache', v:null),
      \ 'grep asks to reuse the file list when the daemon can serve it')

" A symbol search is a project-wide grep and pays the same walk, so it asks too.
call delete(s:log)
SimpleFinderSymbols needle
call s:WaitFor({-> !empty(s:LastRequest('grep'))}, 'the symbol request is sent')
call assert_equal(v:true, get(s:LastRequest('grep'), 'file_cache', v:null),
      \ 'a symbol search reuses the file list as well')

" ── Opting out means every request walks again ──
call s:Restart('files,grep,cancel,match_indices,path_globs,stream,grep_cache')
let g:simplefinder_grep_cache = 0
SimpleFinderIGrep needle
call s:WaitFor({-> !empty(s:LastRequest('grep'))}, 'the opted-out request is sent')
call assert_equal(v:false, get(s:LastRequest('grep'), 'file_cache', v:null),
      \ 'g:simplefinder_grep_cache = 0 walks the tree for every request')
let g:simplefinder_grep_cache = 1

" ── A daemon that predates the field is never asked for it ──
"
" Sending it anyway would be harmless only by luck: the plugin would believe it
" had opted out of the walk while the daemon walked regardless, and no timing
" difference would ever reveal that.
call s:Restart('files,grep,cancel,match_indices,path_globs,stream')
SimpleFinderIGrep needle
call s:WaitFor({-> !empty(s:LastRequest('grep'))}, 'the un-negotiated request is sent')
call assert_false(simplefinder#core#HasCap('grep_cache'),
      \ 'the restarted daemon advertises no grep_cache')
call assert_equal(v:false, get(s:LastRequest('grep'), 'file_cache', v:null),
      \ 'an older daemon is never asked to reuse a list it does not keep')

call simplefinder#Stop()
call delete(s:log)

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/cache-errors.log')
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit
endif
qall!
