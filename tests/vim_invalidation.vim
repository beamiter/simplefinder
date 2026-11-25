set nocompatible nomore
let s:repo = fnamemodify(expand('<sfile>:p:h'), ':h')
execute 'set runtimepath^=' .. fnameescape(s:repo)
let s:base = tempname()
let s:root = s:base .. '/a'
let s:other = s:base .. '/ab'
call mkdir(s:root, 'p')
call mkdir(s:other, 'p')
let $INVALIDATION_LOG = s:base .. '/wire.log'
let $INVALIDATION_CAP = '1'
let g:simplefinder_daemon_path = s:repo .. '/tests/fake_invalidation_daemon.py'
let g:simplefinder_root = s:root
let g:simplefinder_preview = 0
runtime plugin/simplefinder.vim

function! s:Emit(kind, data) abort
  let g:simpletree_event = a:data
  execute 'silent doautocmd <nomodeline> User ' .. a:kind
endfunction

function! s:Requests(kind) abort
  let l:rows = filereadable($INVALIDATION_LOG) ? readfile($INVALIDATION_LOG) : []
  return filter(map(l:rows, 'json_decode(v:val)'), 'v:val.type ==# a:kind')
endfunction

function! s:Until(test, description) abort
  for l:_ in range(100)
    if call(a:test, [])
      return 1
    endif
    sleep 10m
  endfor
  call assert_true(0, 'timeout: ' .. a:description)
  return 0
endfunction

call s:Emit('SimpleTreeFileCreated', {'path': s:root .. '/before', 'is_dir': v:false})
call assert_false(simplefinder#core#IsRunning(), 'Tree must not start a Finder process')
SimpleFinderFiles
call s:Until({-> len(s:Requests('files')) == 1}, 'initial held file request')

call s:Emit('SimpleTreeFileRenamed', {'old': s:other .. '/old', 'new': s:other .. '/new'})
call s:Until({-> len(s:Requests('invalidate_files')) == 1}, 'other root invalidation')
call assert_equal(1, len(s:Requests('files')), '/a may not be repainted by /ab')
call assert_equal([], s:Requests('cancel'), 'other root must not cancel the visible request')
if len(s:Requests('invalidate_files')) == 1
  call assert_equal([s:other .. '/old', s:other .. '/new'], s:Requests('invalidate_files')[0].paths)
endif

call s:Emit('SimpleTreeFileDeleted', {'path': s:root .. '/removed', 'trashed': v:true})
call s:Until({-> len(s:Requests('files')) == 2}, 'post-mutation replacement')
call assert_equal(2, len(s:Requests('invalidate_files')), 'only one invalidation per event')
let s:wire_types = map(readfile($INVALIDATION_LOG), 'json_decode(v:val).type')
call assert_equal(['ping', 'files', 'invalidate_files', 'cancel', 'invalidate_files', 'files'],
      \ s:wire_types, 'the cache fence must be sent before requesting new results')
if len(s:Requests('files')) == 2
  call assert_true(s:Requests('files')[0].id < s:Requests('files')[1].id)
endif
call assert_notmatch('STALE-RETIRED-RESULT', join(getbufline(bufnr('SimpleFinder'), 1, '$'), "\n"),
      \ 'a late old reply may not repaint a retired request')

let before = len(s:Requests('invalidate_files'))
call s:Emit('SimpleTreeFileCreated', {'path': 'relative/../bad', 'is_dir': v:false})
call s:Emit('SimpleTreeFileCreated', {'path': s:root .. '/../escape', 'is_dir': v:false})
call s:Emit('SimpleTreeFileCreated', {'path': ['bad'], 'is_dir': v:false})
call s:Emit('SimpleTreePathsChanged', {'paths': []})
call s:Emit('SimpleTreePathsChanged', {'paths': s:root .. '/not-a-list'})
call s:Emit('SimpleTreePathsChanged', {'paths': [s:root .. '/valid', {'bad': 1}]})
call s:Emit('SimpleTreePathsChanged', {'paths': [s:root .. '/one', s:root .. '/two', s:root .. '/three']})
let g:simpleremote_workspace = {'local_root': s:root}
call s:Emit('SimpleTreeFileCreated', {'path': s:root .. '/projection', 'is_dir': v:false})
call s:Emit('SimpleTreePathsChanged', {'paths': [s:other .. '/valid', s:root .. '/projection']})
if has('unix')
  call system('ln -s ' .. shellescape(s:root) .. ' ' .. shellescape(s:base .. '/alias'))
  call assert_equal(0, v:shell_error, 'symlink test fixture setup')
  call s:Emit('SimpleTreePathsChanged', {'paths': [s:base .. '/alias/projected-through-symlink']})
endif
unlet g:simpleremote_workspace
sleep 30m
call assert_equal(before, len(s:Requests('invalidate_files')), 'malformed event must not reach the daemon')

let g:simplefinder_remote = 0
let g:simpleremote_workspace = {'id': 17, 'kind': 'ssh', 'local_root': s:other,
      \ 'root': '/srv/other', 'target': 'other.invalid', 'mode': 'sshfs'}
call writefile(['test'], s:root .. '/created-locally')
call s:Emit('SimpleTreeFileCreated', {'path': s:root .. '/created-locally', 'is_dir': v:false})
call s:Until({-> len(s:Requests('invalidate_files')) == 3},
      \ 'unrelated remote projection must not suppress an explicitly local root mutation')
call s:Until({-> len(s:Requests('files')) == 3}, 'affected local view must refresh')
call writefile(['test'], s:other .. '/projected-while-local')
call s:Emit('SimpleTreeFileCreated', {'path': s:other .. '/projected-while-local', 'is_dir': v:false})
sleep 30m
call assert_equal(3, len(s:Requests('invalidate_files')),
      \ 'known projected entries stay excluded even while Finder is local')

" Exercise an actual Finder panel following the synthetic registered SSHFS
" workspace. The existing opt-out uses the local daemon to walk that mount,
" so daemon liveness cannot be what excludes its Tree event here.
let g:simplefinder_remote = 1
let g:simplefinder_remote_search_projected = 0
SimpleFinderFiles
call s:Until({-> len(s:Requests('files')) == 4}, 'SSHFS projected panel opens')
call assert_equal(s:other, s:Requests('files')[-1].root)
call s:Emit('SimpleTreeFileDeleted', {'path': s:other .. '/projected-now', 'trashed': v:false})
call s:Emit('SimpleTreeFileDeleted', {'path': s:root .. '/not-the-active-panel', 'trashed': v:false})
sleep 30m
call assert_equal(3, len(s:Requests('invalidate_files')), 'active projected view sends no invalidation')
call assert_equal(4, len(s:Requests('files')), 'active projected view does not refresh')
unlet g:simpleremote_workspace
let g:simplefinder_remote_search_projected = 1

call simplefinder#Stop()
call s:Until({-> !simplefinder#core#IsRunning()}, 'capable daemon stopped')
call delete($INVALIDATION_LOG)
let $INVALIDATION_CAP = '0'
SimpleFinderFiles
call s:Until({-> len(s:Requests('files')) == 1}, 'legacy daemon continues standalone')
call s:Emit('SimpleTreeFileDeleted', {'path': s:root .. '/another'})
call s:Emit('SimpleTreePathsChanged', {'paths': [s:root .. '/local']})
sleep 30m
call assert_equal([], s:Requests('invalidate_files'), 'legacy peer must not receive unknown wire type')
call assert_equal(1, len(s:Requests('files')), 'legacy TTL behavior must stay untouched')
call simplefinder#Stop()
call s:Until({-> !simplefinder#core#IsRunning()}, 'legacy daemon stopped')
call delete($INVALIDATION_LOG)

" Tree paste emits one bounded path set per installed item. Fence them all
" immediately; only the replacement query should be coalesced.
let $INVALIDATION_CAP = '1'
let g:simplefinder_root = s:root
SimpleFinderFiles
call s:Until({-> len(s:Requests('files')) == 1}, 'paste burst original search')
let s:batch = [[s:root .. '/copy1'], [s:root .. '/copy2'], [s:root .. '/old3', s:root .. '/new3']]
for s:paths in s:batch
  call s:Emit('SimpleTreePathsChanged', {'paths': s:paths})
endfor
call s:Until({-> len(s:Requests('files')) >= 2}, 'paste burst replacement')
sleep 60m
call assert_equal(s:batch, map(s:Requests('invalidate_files'), 'v:val.paths'))
call assert_equal(['ping', 'files', 'cancel', 'invalidate_files', 'invalidate_files',
      \ 'invalidate_files', 'files'], map(readfile($INVALIDATION_LOG), 'json_decode(v:val).type'),
      \ 'three exact cache fences must precede one replacement query')
call assert_notmatch('STALE-RETIRED-RESULT',
      \ join(getbufline(bufnr('SimpleFinder'), 1, '$'), "\n"), 'old results stay retired')

call delete($INVALIDATION_LOG)
call s:Emit('SimpleTreePathsChanged', {'paths': [s:root .. '/before-switch']})
tabnew
let g:simplefinder_root = s:other
SimpleFinderFiles
call s:Until({-> len(s:Requests('files')) >= 1}, 'project B opens before the paste timer')
sleep 60m
call assert_equal([s:other], map(s:Requests('files'), 'v:val.root'),
      \ 'a deferred A refresh must not search A or duplicate the new B request')
call assert_equal([[s:root .. '/before-switch']], map(s:Requests('invalidate_files'), 'v:val.paths'),
      \ 'cancel the refresh, not the cache fence')
tabclose
call simplefinder#Stop()
call s:Until({-> !simplefinder#core#IsRunning()}, 'paste burst daemon stopped')
call delete($INVALIDATION_LOG)

" Switch from A to the sibling root B before the A invalidate acknowledgment
" and both A searches return. B retains its own pending request while the
" controlled peer releases the old A acknowledgment and results.
let $INVALIDATION_CAP = '1'
let $INVALIDATION_SWITCH_ROOT = s:other
let $INVALIDATION_SWITCH_BARRIER = s:base .. '/switch'
let g:simplefinder_root = s:root

function! s:PanelText() abort
  let panel = bufnr('SimpleFinder')
  return panel > 0 ? join(getbufline(panel, 1, '$'), "\n") : ''
endfunction

SimpleFinderFiles
call s:Until({-> len(s:Requests('files')) == 1}, 'project A starts')
call s:Emit('SimpleTreeFileRenamed', {'old': s:root .. '/old.rs', 'new': s:root .. '/new.rs'})
call s:Until({-> len(s:Requests('files')) == 2}, 'A restarts while the invalidate acknowledgment is held')
tabnew
let g:simplefinder_root = s:other
SimpleFinderFiles
call s:Until({-> len(s:Requests('files')) == 3}, 'B is in flight before releasing A replies')
call assert_equal([s:root, s:root, s:other], map(s:Requests('files'), 'v:val.root'))
call writefile([], $INVALIDATION_SWITCH_BARRIER .. '.release-a')
call s:Until({-> filereadable($INVALIDATION_SWITCH_BARRIER .. '.a-sent')}, 'held A acknowledgment and stale results released')
sleep 30m
call assert_notmatch('A-LATE-RESULT', s:PanelText(), 'late A results must not repaint B')
call writefile([], $INVALIDATION_SWITCH_BARRIER .. '.finish-b')
call s:Until({-> s:PanelText() =~# 'B-COMPLETE'}, 'the original B request completes after the held A replies')
call assert_equal(1, len(s:Requests('invalidate_files')), 'switch does not invalidate unrelated B')
call assert_notmatch('A-LATE-RESULT', s:PanelText())
call simplefinder#Stop()
call delete(s:base, 'rf')
if len(v:errors)
  call writefile(v:errors, s:repo .. '/tests/invalidation-errors.log')
  cquit
endif
qall!
