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
g:simplefinder_popup_width = get(g:, 'simplefinder_popup_width', 80)
g:simplefinder_popup_height = get(g:, 'simplefinder_popup_height', 20)
g:simplefinder_recent_files_max = get(g:, 'simplefinder_recent_files_max', 100)

# =============================================================
# Commands
# =============================================================
command! -nargs=? SimpleFinderFiles  simplefinder#Files(<q-args>)
command! -nargs=? SimpleFinderGrep   simplefinder#Grep(<q-args>)
command! -nargs=? SimpleFinderIGrep  simplefinder#IGrep(<q-args>)
command! SimpleFinderRecent          simplefinder#RecentFiles()
command! SimpleFinderBuffers         simplefinder#Buffers()

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

# =============================================================
# Autocommands
# =============================================================
augroup SimpleFinder
  autocmd!
  autocmd VimLeavePre * try | simplefinder#Stop() | catch | endtry
  autocmd BufEnter * simplefinder#TrackRecentFile()
augroup END
