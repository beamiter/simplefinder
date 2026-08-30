" Native include/exclude path filters for daemon-backed sources.
"
" Run: vim -Nu NONE -n -i NONE -es -S tests/vim_globs.vim

set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)
call delete(s:root .. '/tests/globs-errors.log')

" A missing daemon has to say so, and has to fail.  `make check` builds it
" (Makefile) before running any of this, so its absence means the build stopped
" producing a daemon -- not an environment worth skipping -- and a bare `qall!`
" here made that indistinguishable from a pass.  `echoerr` is swallowed by the
" silent-ex Vim these suites run under, so the message goes to /dev/stderr, the
" way the SKIP in vim_tabs.vim does.
function! s:Fail(why) abort
  try
    call writefile(['FAIL tests/vim_globs.vim: ' .. a:why], '/dev/stderr')
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
let g:simplefinder_close_on_select = 0
let g:simplefinder_preview = 0
runtime plugin/simplefinder.vim

let s:project = tempname()
call mkdir(s:project .. '/.git', 'p')
call mkdir(s:project .. '/src', 'p')
call mkdir(s:project .. '/docs', 'p')
call writefile(['fn keep_needle() {}'], s:project .. '/src/keep.rs')
call writefile(['fn generated_needle() {}'], s:project .. '/src/skip.generated.rs')
call writefile(['needle documentation'], s:project .. '/docs/readme.md')
let g:simplefinder_root = s:project

function! s:Panel() abort
  return join(getbufline(bufnr('SimpleFinder'), 1, '$'), "\n")
endfunction

function! s:WaitForResult() abort
  let l:tries = 0
  while l:tries < 150 && s:Panel() =~# 'searching'
    sleep 20m
    let l:tries += 1
  endwhile
endfunction

" One native override set is shared by file finding, grep, and symbols.
let g:simplefinder_include_globs = ['*.rs']
let g:simplefinder_exclude_globs = ['*.generated.rs']
SimpleFinderFiles
call s:WaitForResult()
call assert_match('src/keep.rs', s:Panel())
call assert_notmatch('skip.generated.rs', s:Panel())
call assert_notmatch('docs/readme.md', s:Panel())
call assert_match('\[glob +1/-1\]', s:Panel())

SimpleFinderIGrep needle
call s:WaitForResult()
call assert_match('src/keep.rs', s:Panel())
call assert_notmatch('skip.generated.rs', s:Panel())
call assert_notmatch('docs/readme.md', s:Panel())

execute 'edit ' .. fnameescape(s:project .. '/src/keep.rs')
setfiletype rust
SimpleFinderSymbols needle
call s:WaitForResult()
call assert_match('keep_needle', s:Panel())
call assert_notmatch('generated_needle', s:Panel())

" Bad Vim option types fail before a request; malformed glob syntax is
" rejected by the Rust matcher and returned as a visible panel error.
let g:simplefinder_include_globs = '*.rs'
SimpleFinderFiles
call assert_match('must be a list', s:Panel())

let g:simplefinder_include_globs = ['[unclosed']
let g:simplefinder_exclude_globs = []
SimpleFinderFiles
call s:WaitForResult()
call assert_match('invalid include', s:Panel())

call simplefinder#Stop()
call delete(s:project, 'rf')

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/globs-errors.log')
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit
endif
qall!
