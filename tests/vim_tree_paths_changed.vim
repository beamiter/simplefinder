" Exercise the Tree event contract through real Vim and the locked Finder
" daemon. The fixture performs disk mutations itself, not with Tree installed.
set nocompatible nomore
set lines=60 columns=160
let s:repo = fnamemodify(expand('<sfile>:p:h'), ':h')
execute 'set runtimepath^=' .. fnameescape(s:repo)
let s:daemon = s:repo .. '/target/debug/simplefinder-daemon'
if !executable(s:daemon)
  call writefile(['FAIL tests/vim_tree_paths_changed.vim: build the native daemon first'], '/dev/stderr')
  cquit
endif
let g:simplefinder_daemon_path = s:daemon
let g:simplefinder_preview = 0
runtime plugin/simplefinder.vim

let s:base = tempname()
let s:a = s:base .. '/a'
let s:b = s:base .. '/ab'
call mkdir(s:a, 'p')
call mkdir(s:b, 'p')
call writefile(['old'], s:a .. '/before-move.txt')
call writefile(['control'], s:a .. '/keep.txt')
call writefile(['unrelated'], s:b .. '/unrelated.txt')
let s:origin = win_getid()

function! s:Panel() abort
  return join(getbufline(bufnr('SimpleFinder'), 1, '$'), "\n")
endfunction

function! s:Until(Condition, description) abort
  for l:attempt in range(300)
    if call(a:Condition, [])
      return
    endif
    sleep 10m
  endfor
  call assert_report(a:description .. ': ' .. s:Panel())
endfunction

function! s:Open(root) abort
  call win_gotoid(s:origin)
  let g:simplefinder_root = a:root
  SimpleFinderFiles
endfunction

function! s:Changed(paths) abort
  let g:simpletree_event = {'paths': a:paths}
  silent doautocmd <nomodeline> User SimpleTreePathsChanged
  unlet g:simpletree_event
endfunction

call s:Open(s:b)
call s:Until({-> s:Panel() =~# 'unrelated\.txt'}, 'unrelated root cached')
call writefile(['not in the cache'], s:b .. '/unrelated-new.txt')
call s:Open(s:a)
call s:Until({-> s:Panel() =~# 'before-move\.txt'}, 'original file listed')
call assert_true(simplefinder#core#HasCap('invalidate_files'))

call writefile(['new'], s:a .. '/after-copy.txt')
call s:Changed([s:a .. '/after-copy.txt'])
call writefile(['second'], s:a .. '/after-copy-two.txt')
call s:Changed([s:a .. '/after-copy-two.txt'])
call writefile(['third'], s:a .. '/after-copy-three.txt')
call s:Changed([s:a .. '/after-copy-three.txt'])
call s:Until({-> s:Panel() =~# 'after-copy\.txt' && s:Panel() =~# 'after-copy-two\.txt'
      \ && s:Panel() =~# 'after-copy-three\.txt'}, 'three copy destinations refresh Finder')
call assert_match('before-move\.txt', s:Panel(), 'a copy keeps its source')

call assert_equal(0, rename(s:a .. '/before-move.txt', s:a .. '/after-move.txt'))
call s:Changed([s:a .. '/before-move.txt', s:a .. '/after-move.txt'])
call s:Until({-> s:Panel() =~# 'after-move\.txt' && s:Panel() !~# 'before-move\.txt'},
      \ 'two changed paths refresh a move without typing')
call assert_match('keep\.txt', s:Panel(), 'unaffected entry in the same root remains')

call s:Open(s:b)
call s:Until({-> s:Panel() =~# 'unrelated\.txt'}, 'unrelated root reopened')
call assert_notmatch('unrelated-new\.txt', s:Panel(), 'unrelated cache was not globally flushed')

" A single event for a cross-root move must retire both cached walks.
call assert_equal(0, rename(s:a .. '/after-move.txt', s:b .. '/cross-root.txt'))
call s:Changed([s:a .. '/after-move.txt', s:b .. '/cross-root.txt'])
call s:Until({-> s:Panel() =~# 'cross-root\.txt'}, 'visible destination root refreshes')
call s:Open(s:a)
call s:Until({-> s:Panel() =~# 'keep\.txt' && s:Panel() !~# 'after-move\.txt'},
      \ 'non-visible source root is also invalidated')

call simplefinder#Stop()
call delete(s:base, 'rf')
if !empty(v:errors)
  call writefile(v:errors, '/dev/stderr')
  cquit
endif
qall!
