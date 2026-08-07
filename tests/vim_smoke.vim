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

function! s:PanelText() abort
  let l:buf = bufnr('SimpleFinder')
  return l:buf > 0 ? join(getbufline(l:buf, 1, '$'), "\n") : ''
endfunction

function! s:WaitFor(Condition, label) abort
  for l:attempt in range(100)
    if call(a:Condition, [])
      return 1
    endif
    sleep 10m
  endfor
  call assert_true(0, 'timeout: ' .. a:label)
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
let s:lines_source_winid = win_getid()
let s:lines_source_bufnr = bufnr('%')
SimpleFinderLines
call assert_true(s:PanelVisible(), 'lines panel opens')

" <C-l> exports marked results to the exact launching split's location list.
" Marked indices retain result order, and opening the list does not require a
" temporary switch into the source window.
call feedkeys("\<Tab>", 'xt')
call feedkeys("\<C-l>", 'xt')
let s:loc = getloclist(s:lines_source_winid, {'title': 1, 'items': 1})
call assert_match('SimpleFinder lines', s:loc.title)
call assert_equal(1, len(s:loc.items))
call assert_equal(s:lines_source_bufnr, s:loc.items[0].bufnr)
call assert_equal(1, s:loc.items[0].lnum)
call assert_equal(1, get(getwininfo(win_getid()), 0, {})->get('loclist', 0))
lclose

" Marks are stable item identities, not volatile result indices. A query may
" hide a marked row; quickfix still receives its complete snapshot in the
" order rows were first marked. Closing/exporting releases the selection.
let s:marked_file = tempname()
call writefile(['first keep', 'second hidden', 'third keep', 'third keep'],
      \ s:marked_file)
execute 'edit! ' .. fnameescape(s:marked_file)
let s:marked_source_winid = win_getid()
SimpleFinderLines
call feedkeys("\<C-j>\<Tab>\<C-p>\<C-p>\<Tab>zzzz", 'xt')
call s:WaitFor({-> s:PanelText() =~# '0 results'}, 'marked query reaches zero results')
call assert_match('2 marked', s:PanelText())
call feedkeys("\<C-l>", 'xt')
let s:hidden_loc = getloclist(s:marked_source_winid, {'title': 1, 'items': 1})
call assert_match('SimpleFinder lines: zzzz', s:hidden_loc.title)
call assert_equal([2, 1], map(copy(s:hidden_loc.items), {_, item -> item.lnum}),
      \ 'location list includes fully hidden marks in first-mark order')
lclose

" The global quickfix export follows the same all-hidden snapshot path.
SimpleFinderLines
call feedkeys("\<C-j>\<Tab>\<C-p>\<C-p>\<Tab>zzzz", 'xt')
call s:WaitFor({-> s:PanelText() =~# '0 results'}, 'quickfix marked query reaches zero')
call feedkeys("\<C-q>", 'xt')
let s:marked_qf = getqflist({'title': 1, 'items': 1})
call assert_match('SimpleFinder lines: zzzz', s:marked_qf.title)
call assert_equal([2, 1], map(copy(s:marked_qf.items), {_, item -> item.lnum}),
      \ 'hidden marks export in first-mark order')
cclose

" Duplicate-looking results remain independently markable through their
" occurrence identity.
SimpleFinderLines
call feedkeys("\<C-j>\<C-j>\<Tab>\<Tab>\<C-q>", 'xt')
call assert_equal([3, 4], map(getqflist(), {_, item -> item.lnum}))
cclose

" A fresh panel must not inherit an invisible selection from the old ones.
SimpleFinderLines
call feedkeys("\<C-q>", 'xt')
call assert_equal([1, 2, 3, 4], map(getqflist(), {_, item -> item.lnum}))
cclose
call delete(s:marked_file)

" Reusing the launching window for another buffer invalidates the captured
" target. The panel stays focused and reports the boundary instead of putting
" a location list on the wrong editing context.
SimpleFinderLines
let s:panel_winid = win_getid()
call win_execute(s:lines_source_winid, 'enew')
call feedkeys("\<C-l>", 'xt')
call assert_equal(s:panel_winid, win_getid())
call assert_true(s:PanelVisible(), 'invalid source leaves the panel open')
call assert_match('source window changed buffer', s:PanelText())
call feedkeys("\<Esc>", 'xt')

" If the panel itself is moved to a different tab, a bare :lopen would target
" that tab's replacement window. Reject the cross-tab boundary and keep focus
" instead of opening a list in the wrong place.
edit README.md
SimpleFinderLines
wincmd T
let s:panel_tabnr = tabpagenr()
let s:panel_winid = win_getid()
call assert_match('PanelHandleKey', maparg('<C-l>', 'n'))
call feedkeys("\<C-l>", 'mtx')
call assert_equal(s:panel_tabnr, tabpagenr())
call assert_equal(s:panel_winid, win_getid())
call assert_match('source window is in another tab', s:PanelText())
call feedkeys("\<Esc>", 'xt')
tabclose

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
