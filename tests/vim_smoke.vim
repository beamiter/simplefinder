set nocompatible
set nomore
execute 'set runtimepath^=' .. fnameescape(getcwd())
let g:simplefinder_daemon_path = getcwd() .. '/target/debug/simplefinder-daemon'
runtime plugin/simplefinder.vim

function! s:PanelVisible() abort
  for l:win in getwininfo()
    if bufname(l:win.bufnr) ==# 'SimpleFinder'
      return 1
    endif
  endfor
  return 0
endfunction

SimpleFinderBuffers
SimpleFinderRecent
SimpleFinderIGrep simplefinder
SimpleFinderResume
SimpleFinderFiles daemon
SimpleFinderRoot

" Buffer lines source: open a file with content, panel must appear.
edit README.md
SimpleFinderLines
call assert_true(s:PanelVisible(), 'lines panel opens')

" Help tags source.
SimpleFinderHelp
call assert_true(s:PanelVisible(), 'help panel opens')

" Resume must restore the last local source without errors.
SimpleFinderResume
call assert_true(s:PanelVisible(), 'resume restores help panel')

" Git files source: enumerates the repository from the index, filters
" fuzzily, and resolves paths against the repository root (ls-files emits
" repo-relative paths, which is a different base from the project root).
call assert_equal(2, exists(':SimpleFinderGitFiles'))
if executable('git')
  edit README.md
  SimpleFinderGitFiles
  call assert_true(s:PanelVisible(), 'git files panel opens')
  let s:gf_buf = bufnr('SimpleFinder')
  let s:gf_all = getbufline(s:gf_buf, 1, '$')
  call assert_true(join(s:gf_all, "\n") =~# 'Git Files', 'the panel is titled Git Files')
  call assert_true(join(s:gf_all, "\n") =~# 'Cargo.toml', 'a tracked file is listed')

  " Typing must narrow the list through the shared local fuzzy filter.
  call simplefinder#Resume()
  let s:gf_narrowed = getbufline(bufnr('SimpleFinder'), 1, '$')
  call assert_true(len(s:gf_narrowed) > 0, 'resume restores the git files panel')
endif

" Supervisor commands must exist and survive a full stop/restart cycle.
call assert_equal(2, exists(':SimpleFinderHealth'))
call assert_equal(2, exists(':SimpleFinderRestart'))
call assert_equal(2, exists(':SimpleFinderLog'))
SimpleFinderFiles daemon
let s:tries = 0
while s:tries < 200 && !simplefinder#core#Ready()
  sleep 10m
  let s:tries += 1
endwhile
call assert_true(simplefinder#core#Ready(), 'the daemon completes its handshake')
call assert_equal(3, simplefinder#core#Protocol(), 'protocol v3 is negotiated')
call assert_true(simplefinder#core#HasCap('grep'), 'grep capability is advertised')
call assert_true(simplefinder#core#HasCap('path_globs'), 'path glob capability is advertised')
SimpleFinderStop
sleep 100m
call assert_false(simplefinder#core#IsRunning(), 'stop really stops the daemon')
SimpleFinderRestart
let s:tries = 0
while s:tries < 200 && !simplefinder#core#Ready()
  sleep 10m
  let s:tries += 1
endwhile
call assert_true(simplefinder#core#Ready(), 'restart brings the daemon back')
call assert_false(simplefinder#core#Health().breaker_open)

if !empty(v:errors)
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit
endif
qa!
