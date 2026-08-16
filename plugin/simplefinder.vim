vim9script

if exists('g:loaded_simplefinder')
  finish
endif
g:loaded_simplefinder = 1

# =============================================================
# Configuration
# =============================================================
g:simplefinder_debug = get(g:, 'simplefinder_debug', 0)
g:simplefinder_daemon_path = get(g:, 'simplefinder_daemon_path', '')
g:simplefinder_max_results = get(g:, 'simplefinder_max_results', 200)
# Daemon worker threads for the file walk and fuzzy scoring; 0 = one per core.
g:simplefinder_threads = get(g:, 'simplefinder_threads', 0)
# Let grep reuse the file list a recent walk already produced instead of
# walking the tree again for every keystroke.  Set to 0 to walk every time, if
# you create files while a grep panel is open and want them searched at once
# rather than when the list expires.
g:simplefinder_grep_cache = get(g:, 'simplefinder_grep_cache', 1)
g:simplefinder_debounce_ms = get(g:, 'simplefinder_debounce_ms', 50)
g:simplefinder_panel_width = get(g:, 'simplefinder_panel_width', 50)
g:simplefinder_recent_files_max = get(g:, 'simplefinder_recent_files_max', 100)
# Queries kept per source for <C-Up>/<C-Down> recall, for this session only.
g:simplefinder_history_max = get(g:, 'simplefinder_history_max', 50)
# How many buffer lines :SimpleFinderLines collects before it stops.
g:simplefinder_lines_max = get(g:, 'simplefinder_lines_max', 50000)
g:simplefinder_position = get(g:, 'simplefinder_position', 'right')
g:simplefinder_close_on_select = get(g:, 'simplefinder_close_on_select', 1)
g:simplefinder_hidden = get(g:, 'simplefinder_hidden', 0)
g:simplefinder_no_ignore = get(g:, 'simplefinder_no_ignore', 0)
g:simplefinder_regex = get(g:, 'simplefinder_regex', 0)
g:simplefinder_ignore_case = get(g:, 'simplefinder_ignore_case', 0)
g:simplefinder_smart_case = get(g:, 'simplefinder_smart_case', 1)
g:simplefinder_preview = get(g:, 'simplefinder_preview', 1)
g:simplefinder_preview_syntax = get(g:, 'simplefinder_preview_syntax', 1)
g:simplefinder_preview_width = get(g:, 'simplefinder_preview_width', 0)
g:simplefinder_preview_max_bytes = get(g:, 'simplefinder_preview_max_bytes', 2097152)
g:simplefinder_preview_cache = get(g:, 'simplefinder_preview_cache', 4)
# Follow an active SimpleRemote workspace.  Virtual workspaces search through
# its SSH/Docker transport; docker-bind/local-map workspaces use the projected
# root with the normal local daemon (sshfs: see the next option).
g:simplefinder_remote = get(g:, 'simplefinder_remote', 1)
# An sshfs projection is a FUSE mount: the local daemon walking it reads every
# file over SSH.  Search such workspaces through the SimpleRemote transport
# instead (results still open as local files under the mount); 0 walks the
# mount with the local daemon like any other projection.
g:simplefinder_remote_search_projected = get(g:, 'simplefinder_remote_search_projected', 1)
g:simplefinder_root = get(g:, 'simplefinder_root', '')
# Native path filters for daemon-backed files, grep, and symbol searches.
# Includes are positive ignore-style globs; excludes are kept separate so a
# leading `!` cannot accidentally invert user intent.
g:simplefinder_include_globs = get(g:, 'simplefinder_include_globs', [])
g:simplefinder_exclude_globs = get(g:, 'simplefinder_exclude_globs', [])
# Per-filetype keywords that introduce a definition, used by
# :SimpleFinderSymbols. Overrides the built-in table for that filetype.
g:simplefinder_symbol_keywords = get(g:, 'simplefinder_symbol_keywords', {})
# Search every language's keywords regardless of the current filetype.
g:simplefinder_symbol_all_languages = get(g:, 'simplefinder_symbol_all_languages', 0)
g:simplefinder_root_markers = get(g:, 'simplefinder_root_markers', ['.git', 'Cargo.toml', 'package.json', 'go.mod', 'CMakeLists.txt', 'Makefile', '.project_root'])

# =============================================================
# Commands
# =============================================================
command! -nargs=? SimpleFinderFiles  simplefinder#Files(<q-args>)
command! -nargs=? SimpleFinderGrep   simplefinder#Grep(<q-args>)
command! -nargs=? SimpleFinderIGrep  simplefinder#IGrep(<q-args>)
command! SimpleFinderRecent          simplefinder#RecentFiles()
command! SimpleFinderBuffers         simplefinder#Buffers()
command! SimpleFinderGrepWord        simplefinder#GrepWord()
command! -range SimpleFinderGrepVisual simplefinder#GrepVisual()
command! -nargs=? -complete=dir SimpleFinderRoot simplefinder#ProjectRoot(<q-args>)
command! SimpleFinderResume         simplefinder#Resume()
command! SimpleFinderLines          simplefinder#Lines()
command! SimpleFinderHelp           simplefinder#HelpTags()
command! SimpleFinderGitFiles       simplefinder#GitFiles()
command! -nargs=? SimpleFinderSymbols simplefinder#Symbols(<q-args>)
command! SimpleFinderMarks          simplefinder#Marks()
command! SimpleFinderJumps          simplefinder#Jumps()
command! SimpleFinderQuickfix       simplefinder#QuickfixList()
command! SimpleFinderLoclist        simplefinder#QuickfixList(true)
command! SimpleFinderRemoteWorkspaces simplefinder#RemoteWorkspaces()
command! SimpleFinderHealth         simplefinder#Health()
command! SimpleFinderRestart        simplefinder#Restart()
command! SimpleFinderLog            simplefinder#ShowLog()
command! SimpleFinderStop           simplefinder#Stop()

# =============================================================
# Mappings
# =============================================================
# Nothing is mapped by default; these are the targets to map to.  A <Plug>
# name is what lets the command it stands for change — arguments, a wrapper, a
# different mode — without breaking the mapping in someone's vimrc.
nnoremap <silent> <Plug>(simplefinder-files)      <Cmd>SimpleFinderFiles<CR>
nnoremap <silent> <Plug>(simplefinder-gitfiles)   <Cmd>SimpleFinderGitFiles<CR>
nnoremap <silent> <Plug>(simplefinder-grep)       <Cmd>SimpleFinderGrep<CR>
nnoremap <silent> <Plug>(simplefinder-igrep)      <Cmd>SimpleFinderIGrep<CR>
nnoremap <silent> <Plug>(simplefinder-grep-word)  <Cmd>SimpleFinderGrepWord<CR>
nnoremap <silent> <Plug>(simplefinder-buffers)    <Cmd>SimpleFinderBuffers<CR>
nnoremap <silent> <Plug>(simplefinder-recent)     <Cmd>SimpleFinderRecent<CR>
nnoremap <silent> <Plug>(simplefinder-lines)      <Cmd>SimpleFinderLines<CR>
nnoremap <silent> <Plug>(simplefinder-help)       <Cmd>SimpleFinderHelp<CR>
nnoremap <silent> <Plug>(simplefinder-symbols)    <Cmd>SimpleFinderSymbols<CR>
nnoremap <silent> <Plug>(simplefinder-marks)      <Cmd>SimpleFinderMarks<CR>
nnoremap <silent> <Plug>(simplefinder-jumps)      <Cmd>SimpleFinderJumps<CR>
nnoremap <silent> <Plug>(simplefinder-quickfix)   <Cmd>SimpleFinderQuickfix<CR>
nnoremap <silent> <Plug>(simplefinder-loclist)    <Cmd>SimpleFinderLoclist<CR>
nnoremap <silent> <Plug>(simplefinder-resume)     <Cmd>SimpleFinderResume<CR>
nnoremap <silent> <Plug>(simplefinder-remote-workspaces) <Cmd>SimpleFinderRemoteWorkspaces<CR>

# Grepping a Visual selection is the one entry point a user cannot map
# correctly by hand: it has to run *while* Visual mode is still active, since
# the '< and '> marks still describe the previous selection until the current
# one ends.  That makes the exact <Cmd> form load-bearing, so ship it rather
# than asking every user to rediscover it.
xnoremap <silent> <Plug>(simplefinder-grep-visual) <Cmd>SimpleFinderGrepVisual<CR>

# =============================================================
# Highlights
# =============================================================
highlight default SFinderBorder   ctermfg=75  guifg=#5fafff
highlight default SFinderPrompt   ctermfg=75  guifg=#5fafff  cterm=bold gui=bold
highlight default SFinderCursor   ctermfg=75  guifg=#5fafff
highlight default SFinderSep      ctermfg=240 guifg=#585858
highlight default SFinderTitle    ctermfg=75  guifg=#5fafff  cterm=bold gui=bold
highlight default SFinderLnum     ctermfg=180 guifg=#d7af87
highlight default SFinderPath     ctermfg=109 guifg=#87afaf
highlight default SFinderStatus   ctermfg=245 guifg=#8a8a8a
highlight default SFinderSelected ctermfg=NONE guifg=NONE ctermbg=236 guibg=#303030 cterm=bold gui=bold
highlight default SFinderError    ctermfg=203 guifg=#ff5f5f
highlight default SFinderFlag     ctermfg=142 guifg=#afaf00
highlight default SFinderMatch    ctermfg=215 guifg=#ffaf5f cterm=bold gui=bold
highlight default SFinderMarked   ctermfg=114 guifg=#87d787 cterm=bold gui=bold
highlight default SFinderPreviewLine ctermbg=237 guibg=#3a3a3a

# =============================================================
# Autocommands
# =============================================================
augroup SimpleFinder
  autocmd!
  autocmd VimLeavePre * try | simplefinder#Stop() | catch | endtry
  autocmd BufEnter * simplefinder#TrackRecentFile()
  autocmd VimResized * simplefinder#Reflow()
  autocmd TextChanged,TextChangedI SimpleFinder simplefinder#OnPanelTextChanged()
  # Registered whether or not SimpleRemote is installed: a User event nothing
  # fires costs nothing, and the handler reads g:simpleremote_event to tell a
  # workspace switch (Connecting) from a disconnect.
  autocmd User SimpleRemoteConnecting,SimpleRemoteConnected,
    \SimpleRemoteWorkspaceChanged,SimpleRemoteTreeRootChanged,
    \SimpleRemoteDisconnected simplefinder#OnRemoteWorkspace()
  autocmd User SimpleRemoteBufferRead simplefinder#OnRemoteBufferRead()
augroup END
