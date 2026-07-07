vim9script

# =============================================================
# SimpleFinder — fuzzy finder & grep (Vim9 + Rust daemon)
# =============================================================

# ─────────────────── Daemon state ───────────────────

var s_job: any = v:null
var s_running: bool = false
var s_next_id: number = 0

# ─────────────────── Panel state ───────────────────

var s_panel_winid: number = 0
var s_panel_bufnr: number = -1
var s_source_winid: number = 0
var s_mode: string = ''          # 'files' | 'grep' | 'igrep' | 'recent' | 'buffers'
var s_query: string = ''
var s_items: list<dict<any>> = []
var s_cursor_idx: number = 0
var s_total: number = 0
var s_current_id: number = 0
var s_debounce_timer: number = 0
var s_project_root: string = ''
var s_scroll_off: number = 0
var s_eff_width: number = 50
var s_eff_height: number = 20

# ─────────────────── Recent files ───────────────────

var s_recent_files: list<string> = []

# ─────────────────── Logging ───────────────────

def Log(msg: string)
  if get(g:, 'simplefinder_debug', 0) == 0
    return
  endif
  echom '[SimpleFinder] ' .. msg
enddef

# =============================================================
# Daemon communication layer
# =============================================================

def FindBackend(): string
  # Check user-specified path first
  var custom = get(g:, 'simplefinder_daemon_path', '')
  if custom !=# '' && executable(custom)
    return custom
  endif
  # Search in runtimepath
  for dir in split(&runtimepath, ',')
    var p = dir .. '/lib/simplefinder-daemon'
    if executable(p)
      return p
    endif
  endfor
  return ''
enddef

def EnsureBackend(): bool
  if s_running
    return true
  endif
  var cmd = FindBackend()
  if cmd ==# '' || !executable(cmd)
    Log('Backend not found')
    echohl ErrorMsg
    echom '[SimpleFinder] daemon not found. Run install.sh to compile.'
    echohl None
    return false
  endif
  try
    s_job = job_start([cmd], {
      in_io: 'pipe',
      out_mode: 'nl',
      out_cb: (ch, line) => {
        OnDaemonEvent(line)
      },
      err_mode: 'nl',
      err_cb: (ch, line) => {
        Log('stderr: ' .. line)
      },
      exit_cb: (ch, code) => {
        s_running = false
        s_job = v:null
        Log('daemon exited with code ' .. string(code))
      },
      stoponexit: 'term'
    })
  catch
    s_job = v:null
    s_running = false
    return false
  endtry
  s_running = (s_job != v:null)
  return s_running
enddef

def Send(req: dict<any>)
  if !s_running
    return
  endif
  try
    var json = json_encode(req) .. "\n"
    ch_sendraw(s_job, json)
  catch
  endtry
enddef

def NextId(): number
  s_next_id += 1
  return s_next_id
enddef

def OnDaemonEvent(line: string)
  if line ==# ''
    return
  endif
  var ev: any
  try
    ev = json_decode(line)
  catch
    Log('decode error: ' .. line)
    return
  endtry
  if type(ev) != v:t_dict || !has_key(ev, 'type')
    return
  endif

  var id = get(ev, 'id', 0)
  # Only handle events for the current active request
  if id != s_current_id
    return
  endif

  if ev.type ==# 'files_result'
    OnFilesResult(ev)
  elseif ev.type ==# 'grep_result'
    OnGrepResult(ev)
  elseif ev.type ==# 'error'
    Log('error from daemon: ' .. get(ev, 'message', ''))
  endif
enddef

export def Stop()
  if s_job != v:null
    try
      call('job_stop', [s_job])
    catch
    endtry
  endif
  s_running = false
  s_job = v:null
enddef

# =============================================================
# Event handlers
# =============================================================

def OnFilesResult(ev: dict<any>)
  s_items = []
  for item in get(ev, 'items', [])
    add(s_items, {
      path: get(item, 'path', ''),
      score: get(item, 'score', 0),
    })
  endfor
  s_total = get(ev, 'total', len(s_items))
  s_cursor_idx = 0
  PanelRender()
enddef

def OnGrepResult(ev: dict<any>)
  s_items = []
  for item in get(ev, 'items', [])
    add(s_items, {
      path: get(item, 'path', ''),
      lnum: get(item, 'lnum', 0),
      col: get(item, 'col', 0),
      text: get(item, 'text', ''),
    })
  endfor
  s_total = get(ev, 'total', len(s_items))
  s_cursor_idx = 0
  PanelRender()
enddef

# =============================================================
# Project root detection
# =============================================================

def FindProjectRoot(): string
  var markers = ['.git', 'Cargo.toml', 'package.json', 'go.mod', 'CMakeLists.txt', 'Makefile', '.project_root']
  var dir = expand('%:p:h')
  if dir ==# ''
    dir = getcwd()
  endif
  var prev = ''
  while dir !=# prev
    for m in markers
      if isdirectory(dir .. '/' .. m) || filereadable(dir .. '/' .. m)
        return dir
      endif
    endfor
    prev = dir
    dir = fnamemodify(dir, ':h')
  endwhile
  return getcwd()
enddef

# =============================================================
# Panel UI
# =============================================================

def PanelOpen(mode: string, initial_query: string = '')
  if s_panel_winid <= 0 || win_id2win(s_panel_winid) == 0
    s_source_winid = win_getid()
  elseif win_getid() != s_panel_winid
    s_source_winid = win_getid()
  endif

  s_mode = mode
  s_query = initial_query
  s_items = []
  s_cursor_idx = 0
  s_total = 0
  s_current_id = 0
  s_project_root = FindProjectRoot()

  EnsurePanel()
  SetupSyntax()
  PanelRender()
enddef

def EnsurePanel()
  var width = get(g:, 'simplefinder_panel_width', 50)
  width = min([max([width, 24]), max([&columns - 10, 24])])

  if s_panel_bufnr <= 0 || !bufexists(s_panel_bufnr)
    s_panel_bufnr = bufadd('SimpleFinder')
    bufload(s_panel_bufnr)
    setbufvar(s_panel_bufnr, '&buftype', 'nofile')
    setbufvar(s_panel_bufnr, '&bufhidden', 'hide')
    setbufvar(s_panel_bufnr, '&buflisted', 0)
    setbufvar(s_panel_bufnr, '&swapfile', 0)
  endif

  if s_panel_winid <= 0 || win_id2win(s_panel_winid) == 0
    botright vertical new
    s_panel_winid = win_getid()
    execute 'buffer ' .. s_panel_bufnr
  else
    win_gotoid(s_panel_winid)
  endif

  execute 'vertical resize ' .. width
  s_eff_width = winwidth(0)
  s_eff_height = winheight(0)
  setlocal nowrap nonumber norelativenumber signcolumn=no foldcolumn=0
  setlocal nobuflisted noswapfile buftype=nofile bufhidden=hide
  setlocal cursorline nomodifiable
  SetupMappings()
enddef

def PanelClose()
  if s_debounce_timer > 0
    timer_stop(s_debounce_timer)
    s_debounce_timer = 0
  endif
  # Cancel running request
  if s_current_id > 0 && s_running
    Send({type: 'cancel', id: s_current_id})
    s_current_id = 0
  endif
  if s_panel_winid > 0 && win_id2win(s_panel_winid) > 0
    var src = s_source_winid
    win_gotoid(s_panel_winid)
    close
    if src > 0 && win_id2win(src) > 0
      win_gotoid(src)
    endif
  endif
  s_panel_winid = 0
enddef

# Truncate a string to a maximum display width (handles wide/ambiguous glyphs),
# appending an ellipsis when content is cut.
def TruncDisplay(str: string, maxwidth: number): string
  if strdisplaywidth(str) <= maxwidth
    return str
  endif
  if maxwidth <= 1
    return "…"
  endif
  var budget = maxwidth - 1   # leave room for the ellipsis
  var out = ''
  for ch in split(str, '\zs')
    var w = strdisplaywidth(ch)
    if strdisplaywidth(out) + w > budget
      break
    endif
    out ..= ch
  endfor
  return out .. "…"
enddef

def PanelRender()
  if s_panel_winid == 0 || win_id2win(s_panel_winid) == 0 || s_panel_bufnr < 0
    return
  endif

  s_eff_width = winwidth(win_id2win(s_panel_winid))
  s_eff_height = winheight(win_id2win(s_panel_winid))
  var width = s_eff_width
  var lines: list<string> = []

  # Mode icons
  var mode_icons = {
    files: ' ',
    grep: ' ',
    igrep: ' ',
    recent: ' ',
    buffers: '﬘ ',
  }
  var mode_names = {
    files: 'Files',
    grep: 'Grep',
    igrep: 'Interactive Grep',
    recent: 'Recent Files',
    buffers: 'Buffers',
  }

  # Title line
  var icon = get(mode_icons, s_mode, '')
  var title = get(mode_names, s_mode, s_mode)
  var count_str = string(s_total) .. ' results'
  var title_line = ' ' .. icon .. title
  var pad = width - strdisplaywidth(title_line) - strdisplaywidth(count_str)
  if pad < 1
    pad = 1
  endif
  title_line ..= repeat(' ', pad) .. count_str
  add(lines, title_line)

  # Input line
  add(lines, ' > ' .. s_query .. "\u2581")

  # Separator
  add(lines, repeat('─', width))

  # Result items
  var height = s_eff_height
  var max_items = height - 4  # title + input + sep + help
  if max_items < 1
    max_items = 1
  endif

  # Scrolling: ensure cursor is visible
  var scroll_off = 0
  if s_cursor_idx >= max_items
    scroll_off = s_cursor_idx - max_items + 1
  endif
  s_scroll_off = scroll_off

  var display_count = 0
  var idx = scroll_off
  while display_count < max_items && idx < len(s_items)
    add(lines, FormatItemLine(idx, width))
    display_count += 1
    idx += 1
  endwhile

  # Pad empty lines
  while display_count < max_items
    add(lines, '')
    display_count += 1
  endwhile

  # Help line
  add(lines, " \u23ce open  ^v vsplit  ^x split  ^t tab  esc close")

  setbufvar(s_panel_bufnr, '&modifiable', 1)
  setbufline(s_panel_bufnr, 1, lines)
  var extra_start = len(lines) + 1
  var last = getbufinfo(s_panel_bufnr)[0].linecount
  if last >= extra_start
    deletebufline(s_panel_bufnr, extra_start, last)
  endif
  setbufvar(s_panel_bufnr, '&modifiable', 0)
  SyncCursorLine()
enddef

# Move the panel cursor onto the selected result row so cursorline tracks it.
def SyncCursorLine()
  if s_panel_winid == 0 || win_id2win(s_panel_winid) == 0 || s_panel_bufnr < 0
    return
  endif
  if empty(s_items)
    return
  endif
  var bufline = s_cursor_idx - s_scroll_off + 4
  win_execute(s_panel_winid, 'normal! ' .. bufline .. 'G')
enddef

def FormatItemLine(idx: number, width: number): string
  var item = s_items[idx]
  var marker = idx == s_cursor_idx ? "\u25b8 " : '  '
  var line = ''

  if s_mode ==# 'files' || s_mode ==# 'recent'
    line = marker .. get(item, 'path', '')
  elseif s_mode ==# 'grep' || s_mode ==# 'igrep'
    var path = get(item, 'path', '')
    var lnum = get(item, 'lnum', 0)
    var text = get(item, 'text', '')
    line = marker .. path .. ':' .. string(lnum) .. ': ' .. text
  elseif s_mode ==# 'buffers'
    var path = get(item, 'path', '')
    var mod = get(item, 'modified', 0) ? ' [+]' : ''
    line = marker .. path .. mod
  endif

  return TruncDisplay(line, width)
enddef

def PanelMoveCursor(old_idx: number, new_idx: number)
  if s_panel_winid == 0 || win_id2win(s_panel_winid) == 0
    return
  endif

  var height = s_eff_height
  var max_items = height - 4
  if max_items < 1
    max_items = 1
  endif

  # Check if scrolling is needed
  var new_scroll_off = 0
  if new_idx >= max_items
    new_scroll_off = new_idx - max_items + 1
  endif

  if new_scroll_off != s_scroll_off
    # Viewport changed — full re-render needed
    PanelRender()
    return
  endif

  var width = s_eff_width
  # Buffer line = display_position + 4 (title + input + sep + 1-indexed)
  var old_bufline = old_idx - s_scroll_off + 4
  var new_bufline = new_idx - s_scroll_off + 4

  setbufvar(s_panel_bufnr, '&modifiable', 1)
  if old_idx >= 0 && old_idx < len(s_items)
    setbufline(s_panel_bufnr, old_bufline, FormatItemLine(old_idx, width))
  endif
  if new_idx >= 0 && new_idx < len(s_items)
    setbufline(s_panel_bufnr, new_bufline, FormatItemLine(new_idx, width))
  endif
  setbufvar(s_panel_bufnr, '&modifiable', 0)
  SyncCursorLine()
enddef

def SetupSyntax()
  if s_panel_winid == 0 || win_id2win(s_panel_winid) == 0
    return
  endif
  win_execute(s_panel_winid, 'syntax clear')
  win_execute(s_panel_winid, 'syntax match SFinderTitle /^ .\+ \(Files\|Grep\|Interactive Grep\|Recent Files\|Buffers\)/')
  win_execute(s_panel_winid, 'syntax match SFinderStatus /\d\+ results$/')
  win_execute(s_panel_winid, 'syntax match SFinderPrompt /^ > /')
  win_execute(s_panel_winid, 'syntax match SFinderSep /^─\+$/')
  win_execute(s_panel_winid, 'syntax match SFinderLnum /:\d\+:/')
  win_execute(s_panel_winid, 'syntax match SFinderStatus /^ .\+ open.*esc close$/')
enddef

def SetupMappings()
  nnoremap <silent><buffer> <CR> <ScriptCmd>PanelHandleKey(0, '<lt>CR>')<CR>
  nnoremap <silent><buffer> <Esc> <ScriptCmd>PanelHandleKey(0, '<lt>Esc>')<CR>
  nnoremap <silent><buffer> <C-c> <ScriptCmd>PanelHandleKey(0, '<lt>C-c>')<CR>
  nnoremap <silent><buffer> <C-v> <ScriptCmd>PanelHandleKey(0, '<lt>C-v>')<CR>
  nnoremap <silent><buffer> <C-x> <ScriptCmd>PanelHandleKey(0, '<lt>C-x>')<CR>
  nnoremap <silent><buffer> <C-s> <ScriptCmd>PanelHandleKey(0, '<lt>C-s>')<CR>
  nnoremap <silent><buffer> <C-t> <ScriptCmd>PanelHandleKey(0, '<lt>C-t>')<CR>
  nnoremap <silent><buffer> <C-j> <ScriptCmd>PanelHandleKey(0, '<lt>C-j>')<CR>
  nnoremap <silent><buffer> <C-n> <ScriptCmd>PanelHandleKey(0, '<lt>C-n>')<CR>
  nnoremap <silent><buffer> <Down> <ScriptCmd>PanelHandleKey(0, '<lt>Down>')<CR>
  nnoremap <silent><buffer> <Tab> <ScriptCmd>PanelHandleKey(0, '<lt>Tab>')<CR>
  nnoremap <silent><buffer> <C-k> <ScriptCmd>PanelHandleKey(0, '<lt>C-k>')<CR>
  nnoremap <silent><buffer> <C-p> <ScriptCmd>PanelHandleKey(0, '<lt>C-p>')<CR>
  nnoremap <silent><buffer> <Up> <ScriptCmd>PanelHandleKey(0, '<lt>Up>')<CR>
  nnoremap <silent><buffer> <S-Tab> <ScriptCmd>PanelHandleKey(0, '<lt>S-Tab>')<CR>
  nnoremap <silent><buffer> <BS> <ScriptCmd>PanelHandleKey(0, '<lt>BS>')<CR>
  nnoremap <silent><buffer> <C-h> <ScriptCmd>PanelHandleKey(0, '<lt>C-h>')<CR>
  nnoremap <silent><buffer> <C-u> <ScriptCmd>PanelHandleKey(0, '<lt>C-u>')<CR>
  nnoremap <silent><buffer> <C-w> <ScriptCmd>PanelHandleKey(0, '<lt>C-w>')<CR>
  nnoremap <silent><buffer> <Space> <ScriptCmd>PanelHandleKey(0, " ")<CR>

  var chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/:@#~'
  for ch in split(chars, '\zs')
    execute 'nnoremap <silent><buffer> ' .. ch .. ' <ScriptCmd>PanelHandleKey(0, ' .. string(ch) .. ')<CR>'
  endfor
enddef

# ─────────────────── Panel key handling ───────────────────

def PanelHandleKey(winid: number, key: string): bool
  var k = key
  var special_keys = {
    '<Esc>': "\<Esc>",
    '<C-c>': "\<C-c>",
    '<CR>': "\<CR>",
    '<C-v>': "\<C-v>",
    '<C-x>': "\<C-x>",
    '<C-s>': "\<C-s>",
    '<C-t>': "\<C-t>",
    '<C-j>': "\<C-j>",
    '<C-n>': "\<C-n>",
    '<Down>': "\<Down>",
    '<Tab>': "\<Tab>",
    '<C-k>': "\<C-k>",
    '<C-p>': "\<C-p>",
    '<Up>': "\<Up>",
    '<S-Tab>': "\<S-Tab>",
    '<BS>': "\<BS>",
    '<C-h>': "\<C-h>",
    '<C-u>': "\<C-u>",
    '<C-w>': "\<C-w>",
  }
  if has_key(special_keys, key)
    k = special_keys[key]
  endif

  if k ==# "\<Esc>" || k ==# "\<C-c>"
    PanelClose()
    return true
  endif

  if k ==# "\<CR>"
    AcceptItem('edit')
    return true
  endif
  if k ==# "\<C-v>"
    AcceptItem('vsplit')
    return true
  endif
  if k ==# "\<C-x>" || k ==# "\<C-s>"
    AcceptItem('split')
    return true
  endif
  if k ==# "\<C-t>"
    AcceptItem('tabedit')
    return true
  endif

  # Navigation
  if k ==# "\<C-j>" || k ==# "\<C-n>" || k ==# "\<Down>" || k ==# "\<Tab>"
    if s_cursor_idx < len(s_items) - 1
      var old = s_cursor_idx
      s_cursor_idx += 1
      PanelMoveCursor(old, s_cursor_idx)
    endif
    return true
  endif
  if k ==# "\<C-k>" || k ==# "\<C-p>" || k ==# "\<Up>" || k ==# "\<S-Tab>"
    if s_cursor_idx > 0
      var old = s_cursor_idx
      s_cursor_idx -= 1
      PanelMoveCursor(old, s_cursor_idx)
    endif
    return true
  endif

  # Editing
  if k ==# "\<BS>" || k ==# "\<C-h>"
    if len(s_query) > 0
      s_query = strcharpart(s_query, 0, strchars(s_query) - 1)
      DebouncedSearch()
      PanelRender()
    endif
    return true
  endif
  if k ==# "\<C-u>"
    s_query = ''
    DebouncedSearch()
    PanelRender()
    return true
  endif
  if k ==# "\<C-w>"
    # Delete last word
    s_query = substitute(s_query, '\S*\s*$', '', '')
    DebouncedSearch()
    PanelRender()
    return true
  endif

  # Printable character
  if strlen(k) == 1 && char2nr(k) >= 32
    s_query ..= k
    DebouncedSearch()
    PanelRender()
    return true
  endif

  # Consume all other keys
  return true
enddef

# ─────────────────── Debounced search ───────────────────

def DebouncedSearch()
  if s_debounce_timer > 0
    timer_stop(s_debounce_timer)
  endif
  var ms = get(g:, 'simplefinder_debounce_ms', 50)
  s_debounce_timer = timer_start(ms, (id) => {
    s_debounce_timer = 0
    DispatchSearch()
  })
enddef

def DispatchSearch()
  if s_mode ==# 'files'
    SendFilesRequest(s_query)
  elseif s_mode ==# 'grep'
    SendGrepRequest(s_query)
  elseif s_mode ==# 'igrep'
    SendGrepRequest(s_query)
  elseif s_mode ==# 'buffers'
    FilterBuffers()
  elseif s_mode ==# 'recent'
    FilterRecentFiles()
  endif
enddef

# =============================================================
# Search functions — daemon-based
# =============================================================

def SendFilesRequest(query: string)
  if !EnsureBackend()
    return
  endif
  # Cancel previous
  if s_current_id > 0
    Send({type: 'cancel', id: s_current_id})
  endif
  var id = NextId()
  s_current_id = id
  Send({
    type: 'files',
    id: id,
    root: s_project_root,
    query: query,
    max: get(g:, 'simplefinder_max_results', 200),
  })
enddef

def SendGrepRequest(pattern: string)
  if pattern ==# ''
    s_items = []
    s_total = 0
    PanelRender()
    return
  endif
  if !EnsureBackend()
    return
  endif
  # Cancel previous
  if s_current_id > 0
    Send({type: 'cancel', id: s_current_id})
  endif
  var id = NextId()
  s_current_id = id
  Send({
    type: 'grep',
    id: id,
    root: s_project_root,
    pattern: pattern,
    max: get(g:, 'simplefinder_max_results', 200),
  })
enddef

# =============================================================
# Mode entry points
# =============================================================

export def Files(query: string = '')
  PanelOpen('files', query)
  SendFilesRequest(query)
enddef

export def Grep(pattern: string = '')
  var p = pattern
  if p ==# ''
    p = input('Grep: ')
    if p ==# ''
      return
    endif
  endif
  PanelOpen('grep', p)
  SendGrepRequest(p)
enddef

export def IGrep(initial: string = '')
  PanelOpen('igrep', initial)
  if initial !=# ''
    SendGrepRequest(initial)
  endif
enddef

export def GrepWord()
  var word = expand('<cword>')
  if word !=# ''
    PanelOpen('igrep', word)
    SendGrepRequest(word)
  endif
enddef

export def GrepVisual()
  var [_, l1, c1, _] = getpos("'<")
  var [_, l2, c2, _] = getpos("'>")
  var lines = getline(l1, l2)
  if len(lines) == 0
    return
  endif
  if len(lines) == 1
    lines[0] = strpart(lines[0], c1 - 1, c2 - c1 + 1)
  else
    lines[0] = strpart(lines[0], c1 - 1)
    lines[-1] = strpart(lines[-1], 0, c2)
  endif
  var text = join(lines, ' ')
  if text !=# ''
    PanelOpen('igrep', text)
    SendGrepRequest(text)
  endif
enddef

# =============================================================
# Buffers (pure Vim9)
# =============================================================

var s_all_buffers: list<dict<any>> = []

export def Buffers()
  s_all_buffers = []
  for info in getbufinfo({buflisted: 1})
    if info.name ==# '' || getbufvar(info.bufnr, '&buftype') !=# ''
      continue
    endif
    add(s_all_buffers, {
      path: fnamemodify(info.name, ':~:.'),
      bufnr: info.bufnr,
      modified: info.changed,
      lastused: info.lastused,
    })
  endfor
  sort(s_all_buffers, (a, b) => b.lastused - a.lastused)
  PanelOpen('buffers')
  s_items = copy(s_all_buffers)
  s_total = len(s_items)
  PanelRender()
enddef

def FilterBuffers()
  if s_query ==# ''
    s_items = copy(s_all_buffers)
  else
    var by_path: dict<any> = {}
    for buf in s_all_buffers
      by_path[buf.path] = buf
    endfor
    s_items = []
    var paths = mapnew(s_all_buffers, (_, v) => v.path)
    for mp in matchfuzzy(paths, s_query)
      if has_key(by_path, mp)
        add(s_items, by_path[mp])
      endif
    endfor
  endif
  s_total = len(s_items)
  s_cursor_idx = 0
  PanelRender()
enddef

# =============================================================
# Recent files (pure Vim9)
# =============================================================

var s_all_recent: list<dict<any>> = []

export def RecentFiles()
  var combined: list<string> = copy(s_recent_files)
  for f in v:oldfiles
    var fp = fnamemodify(f, ':p')
    if index(combined, fp) < 0 && filereadable(fp)
      add(combined, fp)
    endif
  endfor
  var mx = get(g:, 'simplefinder_recent_files_max', 100)
  if len(combined) > mx
    combined = combined[: mx - 1]
  endif
  s_all_recent = mapnew(combined, (_, f) => ({path: fnamemodify(f, ':~:.')}))
  PanelOpen('recent')
  s_items = copy(s_all_recent)
  s_total = len(s_items)
  PanelRender()
enddef

def FilterRecentFiles()
  if s_query ==# ''
    s_items = copy(s_all_recent)
  else
    var by_path: dict<any> = {}
    for item in s_all_recent
      by_path[item.path] = item
    endfor
    s_items = []
    var paths = mapnew(s_all_recent, (_, v) => v.path)
    for mp in matchfuzzy(paths, s_query)
      if has_key(by_path, mp)
        add(s_items, by_path[mp])
      endif
    endfor
  endif
  s_total = len(s_items)
  s_cursor_idx = 0
  PanelRender()
enddef

export def TrackRecentFile()
  var f = expand('%:p')
  if f ==# '' || !filereadable(f)
    return
  endif
  if &buftype !=# ''
    return
  endif
  filter(s_recent_files, (_, v) => v !=# f)
  insert(s_recent_files, f, 0)
  var mx = get(g:, 'simplefinder_recent_files_max', 100)
  if len(s_recent_files) > mx
    s_recent_files = s_recent_files[: mx - 1]
  endif
enddef

# =============================================================
# Open item
# =============================================================

def AcceptItem(mode: string)
  if len(s_items) == 0 || s_cursor_idx >= len(s_items)
    return
  endif
  var item = s_items[s_cursor_idx]
  var path = get(item, 'path', '')
  var lnum = get(item, 'lnum', 0)
  var col = get(item, 'col', 0)

  # For files/grep results, resolve relative path from project root
  if (s_mode ==# 'files' || s_mode ==# 'grep' || s_mode ==# 'igrep') && s_project_root !=# ''
    if path !=# '' && path[0] !=# '/' && path[0] !=# '~'
      path = s_project_root .. '/' .. path
    endif
  endif

  if s_source_winid > 0 && win_id2win(s_source_winid) > 0
    win_gotoid(s_source_winid)
  endif

  # For buffers, use bufnr if available
  var bufnr = get(item, 'bufnr', -1)
  if bufnr > 0 && mode ==# 'edit'
    execute 'buffer ' .. bufnr
  else
    execute mode .. ' ' .. fnameescape(path)
  endif

  if lnum > 0
    cursor(lnum, max([1, col]))
    normal! zz
  endif

  if s_panel_winid > 0 && win_id2win(s_panel_winid) > 0
    win_gotoid(s_panel_winid)
    SyncCursorLine()
  endif
enddef
