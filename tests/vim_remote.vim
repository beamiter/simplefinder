" SimpleRemote integration: virtual workspaces search without a local mount or
" a second simplefinder-daemon on the target.
"
" Run: vim -Nu NONE -n -i NONE -es -S tests/vim_remote.vim

set nocompatible
set nomore
set columns=160 lines=50

let s:repo = fnamemodify(expand('<sfile>'), ':p:h:h')
call delete('/tmp/simplefinder-remote-errors.log')
let s:first = tempname()
let s:second = tempname()
call mkdir(s:first .. '/src', 'p')
call mkdir(s:second, 'p')
call writefile(['fn alpha() {}', 'needle remote'], s:first .. '/src/alpha.rs')
call writefile(['project one'], s:first .. '/README.md')
call writefile(['beta workspace'], s:second .. '/beta.txt')

let g:simpleremote_workspace = {
      \ 'id': 1, 'kind': 'ssh', 'target': 'fixture-target',
      \ 'root': s:first, 'local_root': '', 'mode': 'virtual'}
let g:remote_preview_reads = 0

function! g:SimpleRemoteShellCommand(command) abort
  let l:root = g:simpleremote_workspace.root
  let l:command = get(g:, 'remote_force_no_rg', 0)
        \ ? substitute(a:command, 'command -v rg >/dev/null 2>&1', 'false', 'g')
        \ : a:command
  return ['sh', '-c', 'cd ' .. shellescape(l:root) .. ' && ' .. l:command]
endfunction

function! s:DeliverRead(Callback, ok, body, timer) abort
  call call(a:Callback, [a:ok, a:body])
endfunction

function! g:SimpleRemoteReadFile(path, Callback) abort
  let g:remote_preview_reads += 1
  let l:path = substitute(a:path, '^remote://', '', '')
  let l:root = g:simpleremote_workspace.root
  if l:path !~# '^' .. escape(l:root, '\') .. '\%(/\|$\)'
    call timer_start(0, function('s:DeliverRead', [a:Callback, 0, 'outside workspace']))
    return -1
  endif
  let l:body = join(readfile(l:path, 'b'), "\n") .. "\n"
  call timer_start(0, function('s:DeliverRead', [a:Callback, 1, l:body]))
  return 1
endfunction

function! g:SimpleRemoteTreeSetRoot(path) abort
  let g:simpleremote_workspace.root = a:path
  let g:simpleremote_workspace.id += 1
  doautocmd <nomodeline> User SimpleRemoteWorkspaceChanged
  return 1
endfunction

function! s:ReadRemoteBuffer() abort
  let l:path = substitute(expand('<amatch>'), '^remote://', '', '')
  setlocal buftype=acwrite bufhidden=hide noswapfile
  silent %delete _
  call setline(1, readfile(l:path))
  setlocal nomodified
endfunction

augroup SimpleFinderRemoteFixture
  autocmd!
  autocmd BufReadCmd remote://* call s:ReadRemoteBuffer()
augroup END

let g:simplefinder_preview = 0
let g:simplefinder_position = 'left'
let g:simplefinder_close_on_select = 1
let g:simplefinder_debounce_ms = 0
execute 'set runtimepath^=' .. fnameescape(s:repo)
runtime plugin/simplefinder.vim

function! s:Panel() abort
  let l:buf = bufnr('SimpleFinder')
  return l:buf > 0 ? join(getbufline(l:buf, 1, '$'), "\n") : ''
endfunction

function! s:WaitFor(Condition, label) abort
  for l:attempt in range(300)
    if call(a:Condition, [])
      return 1
    endif
    sleep 10m
  endfor
  call assert_true(0, 'timeout: ' .. a:label .. ' panel=' .. s:Panel())
  return 0
endfunction

function! s:SearchDone(needle) abort
  let l:text = s:Panel()
  return l:text =~# a:needle && l:text !~# 'searching…'
endfunction

" File enumeration crosses the transport and keeps fuzzy matching local.
SimpleFinderFiles alpha
call s:WaitFor({-> s:SearchDone('src/alpha.rs')}, 'remote file search')
call assert_match('\[ssh:fixture-target\]', s:Panel())
call assert_false(simplefinder#core#IsRunning(),
      \ 'a virtual remote search must not start the local finder daemon')
call feedkeys("\<Esc>", 'xt')

" A virtual result previews through SimpleRemoteReadFile and opens through the
" remote:// BufReadCmd boundary.
let g:simplefinder_preview = 1
SimpleFinderFiles alpha
call s:WaitFor({-> s:SearchDone('src/alpha.rs')}, 'preview file search')
call s:WaitFor({-> g:remote_preview_reads > 0}, 'remote preview read')
call s:WaitFor({-> !empty(popup_list())
      \ && join(getbufline(winbufnr(popup_list()[0]), 1, '$'), "\n") =~# 'fn alpha'},
      \ 'remote preview contents')
call feedkeys("\<CR>", 'xt')
call assert_equal('remote://' .. s:first .. '/src/alpha.rs', bufname())
call assert_equal('needle remote', getline(2))

" Grep-derived entry points share the same transport and path resolution.
let g:simplefinder_preview = 0
SimpleFinderIGrep needle
call s:WaitFor({-> s:SearchDone('src/alpha.rs:2:')}, 'remote interactive grep')
call feedkeys("\<C-q>", 'xt')
let s:qf = getqflist()
call assert_equal(1, len(s:qf))
call assert_equal('remote://' .. s:first .. '/src/alpha.rs',
      \ bufname(s:qf[0].bufnr), 'remote grep exports a remote:// quickfix item')
cclose

" Targets without ripgrep still retain a functional grep path.
let g:remote_force_no_rg = 1
SimpleFinderGrep remote
call s:WaitFor({-> s:SearchDone('src/alpha.rs:2:')}, 'remote grep fallback')
call feedkeys("\<Esc>", 'xt')
let g:remote_force_no_rg = 0

setfiletype rust
SimpleFinderSymbols alpha
call s:WaitFor({-> s:SearchDone('src/alpha.rs:1:')}, 'remote symbol search')
call feedkeys("\<Esc>", 'xt')

" Git files also execute on the target rather than inspecting the local cwd.
if executable('git')
  call system('git -C ' .. shellescape(s:first) .. ' init -q')
  call system('git -C ' .. shellescape(s:first) .. ' add README.md src/alpha.rs')
  SimpleFinderGitFiles
  call s:WaitFor({-> s:SearchDone('src/alpha.rs')}, 'remote git files')
  call feedkeys("\<Esc>", 'xt')
endif

" Pinning the finder root is a workspace operation while remote mode is active;
" the live panel follows the resulting workspace event without being reopened.
SimpleFinderFiles
call s:WaitFor({-> s:SearchDone('src/alpha.rs')}, 'first workspace listing')
call simplefinder#ProjectRoot(s:second)
call assert_equal(s:second, g:simpleremote_workspace.root)
call s:WaitFor({-> s:SearchDone('beta.txt')}, 'finder follows remote root switch')
call assert_notmatch('src/alpha.rs', s:Panel())

let s:saved_workspace = copy(g:simpleremote_workspace)
unlet g:simpleremote_workspace
doautocmd <nomodeline> User SimpleRemoteDisconnected
call assert_match('remote workspace disconnected', s:Panel())
let g:simpleremote_workspace = s:saved_workspace
doautocmd <nomodeline> User SimpleRemoteConnected
call s:WaitFor({-> s:SearchDone('beta.txt')}, 'finder resumes after reconnect')
call feedkeys("\<Esc>", 'xt')

" A projected workspace takes the other branch: the ordinary daemon searches
" local_root and results remain normal filesystem buffers.
let g:simpleremote_workspace = {
      \ 'id': 99, 'kind': 'ssh', 'target': 'fixture-target',
      \ 'root': '/remote/project', 'local_root': s:first, 'mode': 'local-map'}
doautocmd <nomodeline> User SimpleRemoteWorkspaceChanged
SimpleFinderFiles alpha
call s:WaitFor({-> s:SearchDone('src/alpha.rs')}, 'projected remote file search')
call assert_true(simplefinder#core#IsRunning(),
      \ 'a projected workspace keeps the local finder daemon')
call feedkeys("\<CR>", 'xt')
call assert_equal(s:first .. '/src/alpha.rs', bufname())

call simplefinder#Stop()
call delete(s:first, 'rf')
call delete(s:second, 'rf')

if !empty(v:errors)
  call writefile(v:errors, '/tmp/simplefinder-remote-errors.log')
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit
endif
qall!
