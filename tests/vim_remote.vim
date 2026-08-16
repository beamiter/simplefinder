" SimpleRemote integration: virtual workspaces search without a local mount or
" a second simplefinder-daemon on the target.
"
" SimpleRemote itself is never on the runtimepath here.  Its public surface --
" g:simpleremote_workspace, g:simpleremote_event, the User events and the
" g:SimpleRemote* functions -- is faked below, so what is on trial is what
" SimpleFinder does with that contract.
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
      \ 'root': s:first, 'tree_root': s:first, 'local_root': '', 'mode': 'virtual'}
let g:remote_preview_reads = 0
let g:remote_shell_calls = 0

" The workspace root, or its projection when there is one: the fixture has no
" real remote host, so the "remote" scripts run in the local directory that
" plays that part.
function! s:ShellRoot() abort
  let l:ws = g:simpleremote_workspace
  return empty(get(l:ws, 'local_root', '')) ? l:ws.root : l:ws.local_root
endfunction

" Like the real thing, an empty argv when no workspace is ready.
function! g:SimpleRemoteShellCommand(command) abort
  if !exists('g:simpleremote_workspace')
    return []
  endif
  let g:remote_shell_calls += 1
  let g:remote_last_script = a:command
  let l:command = get(g:, 'remote_force_no_rg', 0)
        \ ? substitute(a:command, 'command -v rg >/dev/null 2>&1', 'false', 'g')
        \ : a:command
  return ['sh', '-c', 'cd ' .. shellescape(s:ShellRoot()) .. ' && ' .. l:command]
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

function! g:SimpleRemoteRemotePath(local) abort
  return a:local
endfunction

" What SimpleRemote does with a tree root, in both of its configurations.
"
" With g:simpleremote_sync_tree_root on, the workspace itself moves: the
" switch is queued, and then Disconnected (reason 'reconnect'), Connecting and
" Connected fire with g:simpleremote_workspace unlet in between.  The switch
" stays parked in g:remote_switch_pending until the test finishes it with
" s:FinishSwitch(), so the gap can be observed.  With sync off, only tree_root
" moves and SimpleRemoteTreeRootChanged fires.
function! g:SimpleRemoteTreeSetRoot(path) abort
  if !exists('g:simpleremote_workspace')
    return 0
  endif
  if !get(g:, 'simpleremote_sync_tree_root', 1)
    let g:simpleremote_workspace.tree_root = a:path
    let g:simpleremote_event = {'event': 'SimpleRemoteTreeRootChanged',
          \ 'root': a:path, 'workspace': g:simpleremote_workspace.root,
          \ 'mode': g:simpleremote_workspace.mode, 'status': 'ssh:fixture-target',
          \ 'time': localtime()}
    doautocmd <nomodeline> User SimpleRemoteTreeRootChanged
    return 1
  endif
  let g:remote_switch_pending = a:path
  call timer_start(0, function('s:BeginSwitch'))
  return 1
endfunction

function! s:BeginSwitch(timer) abort
  let s:switch_saved = copy(g:simpleremote_workspace)
  unlet g:simpleremote_workspace
  let g:simpleremote_event = {'event': 'SimpleRemoteDisconnected',
        \ 'reason': 'reconnect', 'status': 'ssh:fixture-target', 'time': localtime()}
  doautocmd <nomodeline> User SimpleRemoteDisconnected
  let g:simpleremote_event = {'event': 'SimpleRemoteConnecting',
        \ 'kind': s:switch_saved.kind, 'target': s:switch_saved.target,
        \ 'root': g:remote_switch_pending, 'status': 'connecting ssh:fixture-target',
        \ 'time': localtime()}
  doautocmd <nomodeline> User SimpleRemoteConnecting
  let g:remote_switch_connecting = 1
endfunction

function! s:FinishSwitch() abort
  let l:ws = s:switch_saved
  let l:ws.root = g:remote_switch_pending
  let l:ws.tree_root = g:remote_switch_pending
  let l:ws.id += 1
  let g:simpleremote_workspace = l:ws
  let g:simpleremote_event = {'event': 'SimpleRemoteConnected',
        \ 'status': 'ssh:fixture-target', 'time': localtime()}
  doautocmd <nomodeline> User SimpleRemoteConnected
  unlet g:remote_switch_pending
  let g:remote_switch_connecting = 0
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
let g:simplefinder_panel_width = 90
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

" The health report, read from its buffer and closed again.
function! s:HealthLines() abort
  SimpleFinderHealth
  let l:lines = getline(1, '$')
  bwipeout!
  return l:lines
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
call assert_equal('acwrite', &buftype, 'the fixture opens remote files like SimpleRemote does')

" ── Buffers: the remote file just opened is a buffer like any other ──
"
" SimpleRemote gives remote:// buffers 'buftype' acwrite so saves go through
" its BufWriteCmd; the buffers source used to drop every buffer with a
" 'buftype', and with it every open remote file.
let g:simplefinder_preview = 0
let s:remote_alpha = bufnr('%')
SimpleFinderBuffers
call assert_match('remote://' .. s:first .. '/src/alpha.rs',
      \ s:Panel(), 'an open remote:// buffer is listed by name')
call assert_match('src/alpha\.rs \[remote\]', s:Panel(), 'and marked as remote')
call feedkeys('alpha', 'xt')
call s:WaitFor({-> s:Panel() =~# 'src/alpha.rs'}, 'buffers filter keeps the remote row')
call feedkeys("\<CR>", 'xt')
call assert_equal(s:remote_alpha, bufnr('%'), '<CR> switches to the remote buffer')

" ── Recent files: remote:// buffers count as visited ──
"
" The remote buffer entered above was tracked on BufEnter (the fixture sets
" 'buftype' acwrite synchronously; SimpleRemote sets it when the asynchronous
" fill lands, and announces that with SimpleRemoteBufferRead, which is the
" other way in).  README.md is "read" through the event alone, without a
" window ever showing it.
let g:simpleremote_event = {'event': 'SimpleRemoteBufferRead', 'type': 'buffer-read',
      \ 'bufnr': 0, 'path': s:first .. '/README.md',
      \ 'workspace': copy(g:simpleremote_workspace),
      \ 'status': 'ssh:fixture-target', 'time': localtime()}
doautocmd <nomodeline> User SimpleRemoteBufferRead
" A local file visited afterwards is the most recent thing of all -- and still
" sorts after the workspace's own files while the workspace is active.
execute 'edit ' .. fnameescape(s:second .. '/beta.txt')
SimpleFinderRecent
let s:recent_rows = filter(split(s:Panel(), "\n"), 'v:val =~# "remote://\\|beta.txt"')
call assert_equal(3, len(s:recent_rows), 'two remote entries and one local: ' .. string(s:recent_rows))
call assert_match('remote://' .. s:first .. '/README.md', s:recent_rows[0],
      \ 'the file read most recently through the event leads')
call assert_match('remote://' .. s:first .. '/src/alpha.rs', s:recent_rows[1],
      \ 'the buffer entered before it follows')
call assert_match('beta.txt', s:recent_rows[2],
      \ 'a local file sorts after the workspace files while a workspace is active')
call feedkeys("\<CR>", 'xt')
call assert_equal('remote://' .. s:first .. '/README.md', bufname(),
      \ 'a recent remote entry opens through the remote:// boundary')
call assert_equal('project one', getline(1))

" Without a workspace the same list keeps its remote entries, in plain
" recency order.
let s:saved_workspace = copy(g:simpleremote_workspace)
unlet g:simpleremote_workspace
execute 'edit ' .. fnameescape(s:second .. '/beta.txt')
SimpleFinderRecent
let s:recent_rows = filter(split(s:Panel(), "\n"), 'v:val =~# "remote://\\|beta.txt"')
call assert_match('beta.txt', s:recent_rows[0], 'no workspace: plain recency order')
call assert_match('remote://' .. s:first .. '/README.md', s:recent_rows[1],
      \ 'remote:// entries are kept without a filereadable() check')
call feedkeys("\<Esc>", 'xt')
let g:simpleremote_workspace = s:saved_workspace

" Grep-derived entry points share the same transport and path resolution.
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

" ── The transport kind is not an allowlist ──
"
" Everything crosses through g:SimpleRemoteShellCommand(), so a kind this
" plugin has never heard of works like ssh; only an empty one is refused.
let g:simpleremote_workspace.kind = 'podman'
SimpleFinderFiles alpha
call s:WaitFor({-> s:SearchDone('src/alpha.rs')}, 'unknown transport kind still searches')
call assert_match('\[podman:fixture-target\]', s:Panel())
call feedkeys("\<Esc>", 'xt')
let g:simpleremote_workspace.kind = 'ssh'

" ── Health names the workspace, the engine, the runtime and the API ──
let g:simpleremote_workspace.runtime = '/opt/simpleremote/lib/simpleremote-daemon'
let g:simpleremote_workspace.protocol = 'json'
let s:health = join(s:HealthLines(), "\n")
call assert_match('\[INFO\] remote workspace: ssh:fixture-target:' .. s:first .. ' (mode virtual)',
      \ s:health)
call assert_match('\[INFO\] remote search: through the SimpleRemote transport in ' .. s:first,
      \ s:health)
call assert_match('\[INFO\] remote transport: /opt/simpleremote/lib/simpleremote-daemon (protocol json)',
      \ s:health)
call assert_match('\[OK\] SimpleRemote API: .*g:SimpleRemoteShellCommand.*present', s:health)
call assert_match('\[INFO\] remote workspace picker: unavailable, missing g:SimpleRemoteRecentWorkspaces',
      \ s:health, 'the picker API is reported on its own, not as a fault of the workspace')
unlet g:simpleremote_workspace.runtime
unlet g:simpleremote_workspace.protocol
let s:health = join(s:HealthLines(), "\n")
call assert_match('\[INFO\] remote transport: ssh/docker fallback', s:health)

" ── Tree root without workspace sync: the finder follows the tree ──
"
" With g:simpleremote_sync_tree_root = 0 re-rooting the tree does not
" reconnect; only tree_root moves and SimpleRemoteTreeRootChanged fires.
" Searches then run there: the script enters the subdirectory, results are
" relative to it and resolve back to absolute remote paths.
let g:simpleremote_sync_tree_root = 0
SimpleFinderFiles
call s:WaitFor({-> s:SearchDone('src/alpha.rs')}, 'workspace-wide listing before re-root')
let s:said = execute('call simplefinder#ProjectRoot(s:first .. "/src")')
call assert_match('remote search root: ' .. s:first .. '/src (workspace root ' .. s:first .. ')',
      \ s:said, 'the message says which root moved')
call assert_equal(s:first, g:simpleremote_workspace.root, 'the workspace root did not move')
call s:WaitFor({-> s:SearchDone('alpha.rs') && s:Panel() !~# 'src/alpha.rs'},
      \ 'the live panel follows the tree root')
call assert_match("cd 'src' && ", g:remote_last_script, 'the script enters the subdirectory')
call assert_notmatch('README.md', s:Panel(), 'files above the tree root are not listed')
call feedkeys("\<CR>", 'xt')
call assert_equal('remote://' .. s:first .. '/src/alpha.rs', bufname(),
      \ 'a result relative to the tree root resolves against it')
let s:health = join(s:HealthLines(), "\n")
call assert_match('\[INFO\] remote tree root: ' .. s:first .. '/src (searches run there',
      \ s:health)
call assert_match('remote search: through the SimpleRemote transport in ' .. s:first .. '/src',
      \ s:health)

" A tree root outside the workspace is not followed, and says so.
let s:said = execute('call simplefinder#ProjectRoot(s:second)')
call assert_match('outside the workspace root', s:said)
call assert_match('searches stay in ' .. s:first, s:said)
SimpleFinderFiles
call s:WaitFor({-> s:SearchDone('src/alpha.rs')}, 'an outside tree root falls back to the workspace')
call feedkeys("\<Esc>", 'xt')

" Back to the root: the same event, the whole workspace again.
call simplefinder#ProjectRoot(s:first)
call assert_equal(s:first, g:simpleremote_workspace.tree_root)
unlet g:simpleremote_sync_tree_root

" With sync on, tree_root only ever differs during a view-only reveal, and a
" reveal must not narrow the search: the panel keeps its listing and does not
" restart it.
SimpleFinderFiles
call s:WaitFor({-> s:SearchDone('src/alpha.rs')}, 'listing before a reveal')
let s:calls = g:remote_shell_calls
let g:simpleremote_workspace.tree_root = s:first .. '/src'
let g:simpleremote_event = {'event': 'SimpleRemoteTreeRootChanged',
      \ 'root': s:first .. '/src', 'workspace': s:first, 'mode': 'virtual',
      \ 'status': 'ssh:fixture-target', 'time': localtime()}
doautocmd <nomodeline> User SimpleRemoteTreeRootChanged
sleep 50m
call assert_equal(s:calls, g:remote_shell_calls, 'a view-only reveal does not restart the search')
call assert_match('src/alpha.rs', s:Panel())
call feedkeys("\<Esc>", 'xt')
let g:simpleremote_workspace.tree_root = s:first

" ── Pinning the finder root is a workspace switch ──
"
" With tree-root sync on, :SimpleFinderRoot {dir} asks SimpleRemote to move
" the workspace, which reconnects: Disconnected (reason 'reconnect'),
" Connecting, Connected, with no workspace published in between.  The panel
" must read that as a switch in progress, not as a disconnection.
SimpleFinderFiles
call s:WaitFor({-> s:SearchDone('src/alpha.rs')}, 'first workspace listing')
let g:remote_switch_connecting = 0
call simplefinder#ProjectRoot(s:second)
call s:WaitFor({-> g:remote_switch_connecting}, 'the switch reaches Connecting')
call assert_false(exists('g:simpleremote_workspace'), 'no workspace is published mid-switch')
call assert_match('searching…', s:Panel(), 'the panel waits for the new root')
call assert_notmatch('disconnected', s:Panel(), 'a switch is not a disconnection')
call assert_match('\[ssh:fixture-target\]', s:Panel(), 'the host stays in the title')
" Typing during the gap: SimpleRemote has no argv to give yet, and the panel
" still says searching rather than "transport unavailable".
call feedkeys('alp', 'xt')
sleep 50m
call assert_match('searching…', s:Panel(), 'a search raised mid-switch waits too')
call assert_notmatch('unavailable', s:Panel())
" A panel opened during the gap follows the connection being replaced too,
" instead of searching whatever the local cwd happens to be; and the root
" cannot be pinned locally while there is no workspace to re-root.
call feedkeys("\<Esc>", 'xt')
SimpleFinderFiles
sleep 50m
call assert_match('Searching…', s:Panel(), 'a panel opened mid-switch waits for the new root')
call assert_match('\[ssh:fixture-target\]', s:Panel())
call assert_false(simplefinder#core#IsRunning(),
      \ 'no local search is started during a workspace switch')
let s:said = execute('call simplefinder#ProjectRoot()')
call assert_match('root: ' .. s:first, s:said,
      \ 'mid-switch the project root is still the workspace being replaced, '
      \ .. 'not the local cwd')
let s:said = execute('call simplefinder#ProjectRoot(s:first)')
call assert_match('switching workspaces', s:said)
call assert_equal('', get(g:, 'simplefinder_root', ''), 'no local root is pinned mid-switch')
call s:FinishSwitch()
call assert_equal(s:second, g:simpleremote_workspace.root)
call s:WaitFor({-> s:SearchDone('beta.txt')}, 'finder follows remote root switch')
call assert_notmatch('src/alpha.rs', s:Panel())

" A real disconnect (any reason but 'reconnect') is still reported, and the
" panel resumes when the workspace comes back.
let s:saved_workspace = copy(g:simpleremote_workspace)
unlet g:simpleremote_workspace
let g:simpleremote_event = {'event': 'SimpleRemoteDisconnected', 'reason': 'disconnect',
      \ 'status': 'disconnected', 'time': localtime()}
doautocmd <nomodeline> User SimpleRemoteDisconnected
call assert_match('remote workspace disconnected', s:Panel())
let g:simpleremote_workspace = s:saved_workspace
let g:simpleremote_event = {'event': 'SimpleRemoteConnected',
      \ 'status': 'ssh:fixture-target', 'time': localtime()}
doautocmd <nomodeline> User SimpleRemoteConnected
call s:WaitFor({-> s:SearchDone('beta.txt')}, 'finder resumes after reconnect')
call feedkeys("\<Esc>", 'xt')

" ── The workspace picker ──
function! g:SimpleRemoteRecentWorkspaces(...) abort
  return [
        \ {'name': '', 'kind': 'ssh', 'target': 'fixture-target', 'root': s:second, 'local_root': ''},
        \ {'name': 'build box', 'kind': 'docker', 'target': 'builder', 'root': '/work', 'local_root': '/mnt/work'},
        \ ]
endfunction
function! g:SimpleRemoteProfiles() abort
  return [
        \ {'name': 'build box', 'kind': 'docker', 'target': 'builder', 'root': '/work', 'local_root': '/mnt/work', 'source': 'profile'},
        \ {'name': 'lab', 'kind': 'ssh', 'target': 'lab.example', 'root': '', 'local_root': '', 'source': 'profile'},
        \ ]
endfunction
let g:remote_opened = {}
function! g:SimpleRemoteOpenWorkspace(workspace) abort
  let g:remote_opened = a:workspace
endfunction

SimpleFinderRemoteWorkspaces
let s:rows = filter(split(s:Panel(), "\n"), 'v:val !~# "^ >" && v:val =~# "ssh:\\|docker:"')
call assert_equal(3, len(s:rows), 'recent + profiles, deduplicated: ' .. string(s:rows))
call assert_match('^.\{-}\* ssh:fixture-target ' .. s:second, s:rows[0],
      \ 'the connected workspace leads the recents and is marked')
call assert_match('build box  docker:builder /work -> /mnt/work$', s:rows[1],
      \ 'a recent workspace that is also a profile is listed once, as the recent')
call assert_match('lab  ssh:lab.example (choose a root) (profile)$', s:rows[2],
      \ 'a profile without a root is offered and labelled')
call feedkeys('lab', 'xt')
call s:WaitFor({-> s:Panel() =~# 'lab.example' && s:Panel() !~# 'builder'}, 'picker filters')
call feedkeys("\<CR>", 'xt')
call assert_equal('lab.example', get(g:remote_opened, 'target', ''),
      \ '<CR> hands the workspace to g:SimpleRemoteOpenWorkspace')
call assert_equal('profile', get(g:remote_opened, 'source', ''))
let s:health = join(s:HealthLines(), "\n")
call assert_match('remote workspace picker: :SimpleFinderRemoteWorkspaces available', s:health)

" ── An sshfs projection searches through the transport ──
"
" The FUSE mount is real enough to open files from, but walking it with the
" local daemon reads every file over SSH.  The workspace is searched on the
" host and results resolve to local paths under the mount.
call simplefinder#Stop()
let g:simpleremote_workspace = {
      \ 'id': 50, 'kind': 'ssh', 'target': 'fixture-target',
      \ 'root': '/remote/project', 'tree_root': '/remote/project',
      \ 'local_root': s:first, 'mode': 'sshfs'}
let g:simpleremote_event = {'event': 'SimpleRemoteConnected',
      \ 'status': 'ssh:fixture-target', 'time': localtime()}
doautocmd <nomodeline> User SimpleRemoteConnected
let s:calls = g:remote_shell_calls
SimpleFinderFiles alpha
call s:WaitFor({-> s:SearchDone('src/alpha.rs')}, 'sshfs file search')
call assert_equal(s:calls + 1, g:remote_shell_calls, 'the listing crossed the transport')
call assert_false(simplefinder#core#IsRunning(),
      \ 'an sshfs projection does not walk the mount with the local daemon')
call assert_match('\[ssh:fixture-target\]', s:Panel())
call feedkeys("\<CR>", 'xt')
call assert_equal(s:first .. '/src/alpha.rs', bufname(),
      \ 'a transport result under a projection opens as a local file')
call assert_equal('', &buftype)
let s:health = join(s:HealthLines(), "\n")
call assert_match('remote workspace: ssh:fixture-target:/remote/project (mode sshfs, projected to '
      \ .. s:first .. ')', s:health)
call assert_match('remote search: through the SimpleRemote transport in /remote/project '
      \ .. '(g:simplefinder_remote_search_projected = 1)', s:health)

" Grep on the same projection: local paths in the quickfix list.
SimpleFinderIGrep needle
call s:WaitFor({-> s:SearchDone('src/alpha.rs:2:')}, 'sshfs grep')
call feedkeys("\<C-q>", 'xt')
let s:qf = getqflist()
call assert_equal(1, len(s:qf))
call assert_equal(s:first .. '/src/alpha.rs', bufname(s:qf[0].bufnr),
      \ 'sshfs grep exports a local quickfix item')
cclose

" The setting hands the mount back to the local daemon.
let g:simplefinder_remote_search_projected = 0
SimpleFinderFiles alpha
call s:WaitFor({-> s:SearchDone('src/alpha.rs')}, 'sshfs search with projected search off')
call assert_true(simplefinder#core#IsRunning(), 'off: the local daemon walks the mount')
call assert_notmatch('\[ssh:fixture-target\]', s:Panel())
call feedkeys("\<CR>", 'xt')
call assert_equal(s:first .. '/src/alpha.rs', bufname())
let s:health = join(s:HealthLines(), "\n")
call assert_match('remote search: local daemon on ' .. s:first
      \ .. ' (g:simplefinder_remote_search_projected = 0)', s:health)
let g:simplefinder_remote_search_projected = 1
call simplefinder#Stop()

" ── A mount coming up does not restart the search that is already running ──
"
" SimpleRemote publishes mode 'mounting' with no local_root until the FUSE
" mount is ready, then WorkspaceChanged with local_root and mode 'sshfs'.
" Same connection, same root, same engine: the listing in flight is kept and
" its results simply resolve to the mount from then on.
let g:simpleremote_workspace = {
      \ 'id': 51, 'kind': 'ssh', 'target': 'fixture-target',
      \ 'root': s:first, 'tree_root': s:first, 'local_root': '', 'mode': 'mounting'}
let g:simpleremote_event = {'event': 'SimpleRemoteConnected',
      \ 'status': 'ssh:fixture-target', 'time': localtime()}
doautocmd <nomodeline> User SimpleRemoteConnected
SimpleFinderFiles alpha
call s:WaitFor({-> s:SearchDone('src/alpha.rs')}, 'listing while mounting')
let s:calls = g:remote_shell_calls
let g:simpleremote_workspace.local_root = s:first
let g:simpleremote_workspace.mode = 'sshfs'
let g:simpleremote_event = {'event': 'SimpleRemoteWorkspaceChanged',
      \ 'status': 'ssh:fixture-target', 'time': localtime()}
doautocmd <nomodeline> User SimpleRemoteWorkspaceChanged
sleep 50m
call assert_equal(s:calls, g:remote_shell_calls,
      \ 'the projection coming up does not re-list the same workspace')
call assert_match('src/alpha.rs', s:Panel())
call feedkeys("\<CR>", 'xt')
call assert_equal(s:first .. '/src/alpha.rs', bufname(),
      \ 'results listed while mounting open under the mount once it is up')

" A projected workspace of another mode takes the other branch: the ordinary
" daemon searches local_root and results remain normal filesystem buffers.
let g:simpleremote_workspace = {
      \ 'id': 99, 'kind': 'ssh', 'target': 'fixture-target',
      \ 'root': '/remote/project', 'local_root': s:first, 'mode': 'local-map'}
let g:simpleremote_event = {'event': 'SimpleRemoteWorkspaceChanged',
      \ 'status': 'ssh:fixture-target', 'time': localtime()}
doautocmd <nomodeline> User SimpleRemoteWorkspaceChanged
SimpleFinderFiles alpha
call s:WaitFor({-> s:SearchDone('src/alpha.rs')}, 'projected remote file search')
call assert_true(simplefinder#core#IsRunning(),
      \ 'a projected workspace keeps the local finder daemon')
call feedkeys("\<CR>", 'xt')
call assert_equal(s:first .. '/src/alpha.rs', bufname())

" A SimpleRemote event about a workspace the finder is not following (the
" integration switched off) must not touch a local search.
call feedkeys("\<Esc>", 'xt')
let g:simplefinder_remote = 0
let g:simplefinder_root = s:first
SimpleFinderFiles alpha
call s:WaitFor({-> s:SearchDone('src/alpha.rs')}, 'local search with the integration off')
let g:simpleremote_event = {'event': 'SimpleRemoteWorkspaceChanged',
      \ 'status': 'ssh:fixture-target', 'time': localtime()}
doautocmd <nomodeline> User SimpleRemoteWorkspaceChanged
call assert_match('src/alpha.rs', s:Panel(), 'the local listing is untouched')
call assert_notmatch('Searching…', s:Panel())
call feedkeys("\<Esc>", 'xt')
let s:health = join(s:HealthLines(), "\n")
call assert_match('\[INFO\] remote workspace: inactive (g:simplefinder_remote = 0)', s:health,
      \ 'health says why the workspace is not followed')
call assert_match('remote workspace picker: :SimpleFinderRemoteWorkspaces available', s:health,
      \ 'the picker is reported without a workspace too: it is how you get one')
let g:simplefinder_remote = 1
let g:simplefinder_root = ''

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
