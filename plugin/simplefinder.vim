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
g:simplefinder_debounce_ms = get(g:, 'simplefinder_debounce_ms', 50)
g:simplefinder_panel_width = get(g:, 'simplefinder_panel_width', 50)
g:simplefinder_recent_files_max = get(g:, 'simplefinder_recent_files_max', 100)
g:simplefinder_position = get(g:, 'simplefinder_position', 'right')
g:simplefinder_close_on_select = get(g:, 'simplefinder_close_on_select', 1)
g:simplefinder_hidden = get(g:, 'simplefinder_hidden', 0)
g:simplefinder_no_ignore = get(g:, 'simplefinder_no_ignore', 0)
g:simplefinder_regex = get(g:, 'simplefinder_regex', 0)
g:simplefinder_ignore_case = get(g:, 'simplefinder_ignore_case', 0)
g:simplefinder_smart_case = get(g:, 'simplefinder_smart_case', 1)
g:simplefinder_preview = get(g:, 'simplefinder_preview', 1)
g:simplefinder_root = get(g:, 'simplefinder_root', '')
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
command! SimpleFinderHealth         simplefinder#Health()
command! SimpleFinderRestart        simplefinder#Restart()
command! SimpleFinderLog            simplefinder#ShowLog()
command! SimpleFinderStop           simplefinder#Stop()

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
augroup END
