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

if !empty(v:errors)
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit
endif
qa!
