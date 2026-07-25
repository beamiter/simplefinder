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
var s_loading: bool = false
var s_error: string = ''
var s_elapsed_ms: number = 0
var s_capped: bool = false
var s_regex: bool = false
var s_case_mode: string = 'smart'   # 'smart' | 'ignore' | 'sensitive'
var s_hidden: bool = false
var s_no_ignore: bool = false
var s_marked: dict<bool> = {}       # multi-select: item index -> marked
var s_preview_on: bool = false
var s_preview_winid: number = 0
var s_has_session: bool = false     # a search was opened before (for Resume)

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
        if s_current_id > 0
          s_loading = false
          s_error = 'Backend exited unexpectedly (code ' .. string(code) .. ')'
          s_current_id = 0
          PanelRender()
        endif
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
    s_loading = false
    s_error = get(ev, 'message', 'Unknown backend error')
    s_current_id = 0
    Log('error from daemon: ' .. s_error)
    PanelRender()
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
      indices: get(item, 'indices', []),
    })
  endfor
  s_total = get(ev, 'total', len(s_items))
  s_capped = get(ev, 'capped', false)
  s_elapsed_ms = get(ev, 'elapsed_ms', 0)
  s_loading = false
  s_error = ''
  s_current_id = 0
  s_cursor_idx = 0
  s_scroll_off = 0
  s_marked = {}
  PanelRender()
enddef

def OnGrepResult(ev: dict<any>)
  s_items = []
  for item in get(ev, 'items', [])
    add(s_items, {
      path: get(item, 'path', ''),
      lnum: get(item, 'lnum', 0),
      col: get(item, 'col', 0),
      col_end: get(item, 'col_end', 0),
      text: get(item, 'text', ''),
    })
  endfor
  s_total = get(ev, 'total', len(s_items))
  s_capped = get(ev, 'capped', false)
  s_elapsed_ms = get(ev, 'elapsed_ms', 0)
  s_loading = false
  s_error = ''
  s_current_id = 0
  s_cursor_idx = 0
  s_scroll_off = 0
  s_marked = {}
  PanelRender()
enddef

# =============================================================
# Project root detection
# =============================================================

def FindProjectRoot(): string
  var configured = get(g:, 'simplefinder_root', '')
  if configured !=# ''
    var root = fnamemodify(expand(configured), ':p')
    if isdirectory(root)
      return substitute(root, '/$', '', '')
    endif
  endif
  var markers = get(g:, 'simplefinder_root_markers', ['.git', 'Cargo.toml', 'package.json', 'go.mod', 'CMakeLists.txt', 'Makefile', '.project_root'])
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

def PanelOpen(mode: string, initial_query: string = '', keep_options: bool = false)
  if s_panel_winid <= 0 || win_id2win(s_panel_winid) == 0
    s_source_winid = win_getid()
  elseif win_getid() != s_panel_winid
    s_source_winid = win_getid()
  endif

  s_mode = mode
  s_query = initial_query
  s_items = []
  s_cursor_idx = 0
  s_scroll_off = 0
  s_total = 0
  s_current_id = 0
  s_loading = false
  s_error = ''
  s_elapsed_ms = 0
  s_capped = false
  s_marked = {}
  s_has_session = true
  if !keep_options
    s_regex = get(g:, 'simplefinder_regex', 0) != 0
    if get(g:, 'simplefinder_ignore_case', 0) != 0
      s_case_mode = 'ignore'
    elseif get(g:, 'simplefinder_smart_case', 1) != 0
      s_case_mode = 'smart'
    else
      s_case_mode = 'sensitive'
    endif
    s_hidden = get(g:, 'simplefinder_hidden', 0) != 0
    s_no_ignore = get(g:, 'simplefinder_no_ignore', 0) != 0
  endif
  s_preview_on = get(g:, 'simplefinder_preview', 1) != 0
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
    if get(g:, 'simplefinder_position', 'right') ==# 'left'
      execute 'topleft vertical sbuffer ' .. s_panel_bufnr
    else
      execute 'botright vertical sbuffer ' .. s_panel_bufnr
    endif
    s_panel_winid = win_getid()
  else
    win_gotoid(s_panel_winid)
  endif

  execute 'vertical resize ' .. width
  s_eff_width = winwidth(0)
  s_eff_height = winheight(0)
  setlocal nowrap nonumber norelativenumber signcolumn=no foldcolumn=0
  setlocal nobuflisted noswapfile buftype=nofile bufhidden=hide
  setlocal cursorline nomodifiable
  setlocal winfixwidth
  if empty(prop_type_get('sf_match', {bufnr: s_panel_bufnr}))
    prop_type_add('sf_match', {bufnr: s_panel_bufnr, highlight: 'SFinderMatch', combine: true})
  endif
  SetupMappings()
enddef

def PanelClose()
  PreviewClose()
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
    if winnr('$') > 1
      close
    else
      enew
      setlocal nobuflisted bufhidden=wipe
    endif
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

  var mode_names = {
    files: 'Files',
    grep: 'Grep',
    igrep: 'Interactive Grep',
    recent: 'Recent Files',
    buffers: 'Buffers',
  }

  # Title line
  var title = get(mode_names, s_mode, s_mode)
  var count_str = ''
  if s_loading
    count_str = 'searching…'
  elseif s_error !=# ''
    count_str = 'error'
  elseif s_capped
    count_str = string(len(s_items)) .. '+ results'
  elseif s_total != len(s_items)
    count_str = string(len(s_items)) .. '/' .. string(s_total) .. ' results'
  else
    count_str = string(s_total) .. ' results'
  endif
  if !s_loading && s_error ==# '' && s_elapsed_ms > 0
    count_str ..= ' · ' .. string(s_elapsed_ms) .. 'ms'
  endif
  if !empty(s_marked)
    count_str = string(len(s_marked)) .. ' marked · ' .. count_str
  endif
  var title_line = ' ' .. title
  var pad = width - strdisplaywidth(title_line) - strdisplaywidth(count_str)
  if pad < 1
    pad = 1
  endif
  title_line ..= repeat(' ', pad) .. count_str
  add(lines, title_line)

  # Input line and active search flags
  var flags = ''
  if s_mode ==# 'grep' || s_mode ==# 'igrep'
    flags ..= s_regex ? ' [.*]' : ' [txt]'
    if s_case_mode ==# 'smart'
      flags ..= ' [sC]'
    elseif s_case_mode ==# 'ignore'
      flags ..= ' [aa]'
    else
      flags ..= ' [Aa]'
    endif
  endif
  if s_hidden
    flags ..= ' [hidden]'
  endif
  if s_no_ignore
    flags ..= ' [all]'
  endif
  add(lines, TruncDisplay(' > ' .. s_query .. "\u2581" .. flags, width))

  # Separator
  add(lines, repeat('─', width))

  # Result items
  var height = s_eff_height
  var max_items = height - 4  # title + input + sep + help
  if max_items < 1
    max_items = 1
  endif

  # Scrolling: keep the viewport stable, only shift when the cursor leaves it
  var scroll_off = s_scroll_off
  if s_cursor_idx < scroll_off
    scroll_off = s_cursor_idx
  elseif s_cursor_idx >= scroll_off + max_items
    scroll_off = s_cursor_idx - max_items + 1
  endif
  var max_off = max([0, len(s_items) - max_items])
  if scroll_off > max_off
    scroll_off = max_off
  endif
  s_scroll_off = scroll_off

  var display_count = 0
  var idx = scroll_off
  while display_count < max_items && idx < len(s_items)
    add(lines, FormatItemLine(idx, width))
    display_count += 1
    idx += 1
  endwhile

  if display_count == 0
    if s_error !=# ''
      add(lines, TruncDisplay(' ! ' .. s_error, width))
      display_count += 1
    elseif s_loading
      add(lines, '   Searching…')
      display_count += 1
    elseif (s_mode ==# 'grep' || s_mode ==# 'igrep') && s_query ==# ''
      add(lines, '   Type to search project text')
      display_count += 1
    else
      add(lines, '   No matches')
      display_count += 1
    endif
  endif

  # Pad empty lines
  while display_count < max_items
    add(lines, '')
    display_count += 1
  endwhile

  # Help line
  var help = " \u23ce open  \u21e5 mark  ^q quickfix  ^e preview  esc close"
  if s_mode ==# 'grep' || s_mode ==# 'igrep'
    help = ' ^r regex  ^a case  ^o hidden  ^g ignores  ^q quickfix'
  elseif s_mode ==# 'buffers'
    help = " \u23ce open  \u21e5 mark  ^d bdelete  ^q quickfix  esc close"
  endif
  add(lines, TruncDisplay(help, width))

  setbufvar(s_panel_bufnr, '&modifiable', 1)
  setbufline(s_panel_bufnr, 1, lines)
  var extra_start = len(lines) + 1
  var last = getbufinfo(s_panel_bufnr)[0].linecount
  if last >= extra_start
    deletebufline(s_panel_bufnr, extra_start, last)
  endif
  setbufvar(s_panel_bufnr, '&modifiable', 0)

  # Highlight matched characters on the visible rows
  try
    prop_remove({type: 'sf_match', bufnr: s_panel_bufnr, all: true})
  catch
  endtry
  var pidx = scroll_off
  var pcount = 0
  while pcount < max_items && pidx < len(s_items)
    AddItemProps(pidx)
    pcount += 1
    pidx += 1
  endwhile

  SyncCursorLine()
  PreviewUpdate()
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

# 3-char row prefix: cursor indicator, multi-select mark, space.
def ItemMarker(idx: number): string
  var cursor_ch = idx == s_cursor_idx ? "\u25b8" : ' '
  var mark_ch = has_key(s_marked, string(idx)) ? '*' : ' '
  return cursor_ch .. mark_ch .. ' '
enddef

def FormatItemLine(idx: number, width: number): string
  var item = s_items[idx]
  var marker = ItemMarker(idx)
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

# Add match-highlight text properties for one visible item row.
def AddItemProps(idx: number)
  if idx < s_scroll_off || s_panel_bufnr < 0
    return
  endif
  var bufline = idx - s_scroll_off + 4
  var line = FormatItemLine(idx, s_eff_width)
  var item = s_items[idx]
  try
    if s_mode ==# 'grep' || s_mode ==# 'igrep'
      var col = get(item, 'col', 0)
      var col_end = get(item, 'col_end', 0)
      if col <= 0 || col_end <= col
        return
      endif
      var prefix = ItemMarker(idx) .. get(item, 'path', '') .. ':'
        .. string(get(item, 'lnum', 0)) .. ': '
      var start = strlen(prefix) + col - 1     # 0-based byte offset in line
      var maxb = strlen(line)
      if start >= maxb
        return
      endif
      var length = min([col_end - col, maxb - start])
      prop_add(bufline, start + 1, {type: 'sf_match', bufnr: s_panel_bufnr, length: length})
    else
      var truncated = line =~# "\u2026$"
      var last_ci = strchars(line) - 1
      for i in get(item, 'indices', [])
        var ci = 3 + i
        if truncated && ci >= last_ci
          break
        endif
        var b0 = byteidx(line, ci)
        if b0 < 0
          break
        endif
        var b1 = byteidx(line, ci + 1)
        if b1 < 0
          b1 = strlen(line)
        endif
        prop_add(bufline, b0 + 1, {type: 'sf_match', bufnr: s_panel_bufnr, length: b1 - b0})
      endfor
    endif
  catch
  endtry
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

  # Check if scrolling is needed (viewport shifts only when cursor leaves it)
  var new_scroll_off = s_scroll_off
  if new_idx < new_scroll_off
    new_scroll_off = new_idx
  elseif new_idx >= new_scroll_off + max_items
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
  if old_idx >= 0 && old_idx < len(s_items)
    AddItemProps(old_idx)
  endif
  if new_idx >= 0 && new_idx < len(s_items)
    AddItemProps(new_idx)
  endif
  SyncCursorLine()
  PreviewUpdate()
enddef

def SetupSyntax()
  if s_panel_winid == 0 || win_id2win(s_panel_winid) == 0
    return
  endif
  win_execute(s_panel_winid, 'syntax clear')
  win_execute(s_panel_winid, 'syntax match SFinderTitle /^ .\+ \(Files\|Grep\|Interactive Grep\|Recent Files\|Buffers\)/')
  win_execute(s_panel_winid, 'syntax match SFinderStatus /\d\+ results$/')
  win_execute(s_panel_winid, 'syntax match SFinderPrompt /^ > /')
  win_execute(s_panel_winid, 'syntax match SFinderError /^ ! .*/')
  win_execute(s_panel_winid, 'syntax match SFinderFlag /\[[^]]\+\]/')
  win_execute(s_panel_winid, 'syntax match SFinderSep /^─\+$/')
  win_execute(s_panel_winid, 'syntax match SFinderLnum /:\d\+:/')
  win_execute(s_panel_winid, 'syntax match SFinderStatus /^ \(⏎ open\|\^r regex\).*$/')
  win_execute(s_panel_winid, 'syntax match SFinderMarked /\%2v\*/')
enddef

# ─────────────────── Preview popup ───────────────────

def PreviewClose()
  if s_preview_winid > 0
    try
      popup_close(s_preview_winid)
    catch
    endtry
    s_preview_winid = 0
  endif
enddef

def PreviewUpdate()
  if !s_preview_on || s_panel_winid == 0 || win_id2win(s_panel_winid) == 0
    PreviewClose()
    return
  endif
  if empty(s_items) || s_cursor_idx >= len(s_items)
    PreviewClose()
    return
  endif
  var item = s_items[s_cursor_idx]
  var path = fnamemodify(expand(ResolvePath(item)), ':p')
  if path ==# '' || !filereadable(path)
    PreviewClose()
    return
  endif

  # Fill the space beside the panel; skip when too narrow to be useful
  var [_, pcol] = win_screenpos(win_id2win(s_panel_winid))
  var width = 0
  var col = 2
  if get(g:, 'simplefinder_position', 'right') !=# 'left'
    width = pcol - 4
    col = 2
  else
    col = pcol + s_eff_width + 3
    width = &columns - col - 1
  endif
  if width < 30
    PreviewClose()
    return
  endif
  var height = max([5, s_eff_height - 2])

  var lnum = get(item, 'lnum', 0)
  var lines: list<string> = []
  var hl_line = 0
  var fsize = getfsize(path)
  if fsize < 0 || fsize > 2097152
    lines = ['── file too large to preview ──']
  else
    var start = 1
    if lnum > 0
      start = max([1, lnum - height / 2])
    endif
    var raw = readfile(path, '', start + height - 1)
    lines = len(raw) > start - 1 ? raw[start - 1 :] : []
    if empty(lines)
      lines = ['── empty file ──']
    elseif lnum > 0
      hl_line = lnum - start + 1
    endif
  endif

  var title = ' ' .. TruncDisplay(get(item, 'path', ''), width - 4) .. ' '
  if s_preview_winid <= 0 || empty(popup_getpos(s_preview_winid))
    s_preview_winid = popup_create(lines, {
      line: 2,
      col: col,
      minwidth: width,
      maxwidth: width,
      minheight: height,
      maxheight: height,
      border: [1, 1, 1, 1],
      borderchars: ['─', '│', '─', '│', '╭', '╮', '╯', '╰'],
      borderhighlight: ['SFinderBorder'],
      title: title,
      wrap: false,
      zindex: 60,
    })
  else
    popup_settext(s_preview_winid, lines)
    popup_setoptions(s_preview_winid, {
      line: 2,
      col: col,
      minwidth: width,
      maxwidth: width,
      minheight: height,
      maxheight: height,
      title: title,
    })
  endif
  win_execute(s_preview_winid, 'call clearmatches()')
  if hl_line > 0
    win_execute(s_preview_winid, 'call matchaddpos("SFinderPreviewLine", [' .. hl_line .. '])')
  endif
enddef

def PanelHandleChar(code: number)
  PanelHandleKey(0, nr2char(code))
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
  nnoremap <silent><buffer> <C-r> <ScriptCmd>PanelHandleKey(0, '<lt>C-r>')<CR>
  nnoremap <silent><buffer> <C-a> <ScriptCmd>PanelHandleKey(0, '<lt>C-a>')<CR>
  nnoremap <silent><buffer> <C-o> <ScriptCmd>PanelHandleKey(0, '<lt>C-o>')<CR>
  nnoremap <silent><buffer> <C-g> <ScriptCmd>PanelHandleKey(0, '<lt>C-g>')<CR>
  nnoremap <silent><buffer> <C-e> <ScriptCmd>PanelHandleKey(0, '<lt>C-e>')<CR>
  nnoremap <silent><buffer> <C-q> <ScriptCmd>PanelHandleKey(0, '<lt>C-q>')<CR>
  nnoremap <silent><buffer> <C-d> <ScriptCmd>PanelHandleKey(0, '<lt>C-d>')<CR>

  # Map the complete printable ASCII range, including regex punctuation.
  for code in range(32, 126)
    execute 'nnoremap <silent><buffer> <Char-' .. code .. '> <ScriptCmd>PanelHandleChar(' .. code .. ')<CR>'
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
    '<C-r>': "\<C-r>",
    '<C-a>': "\<C-a>",
    '<C-o>': "\<C-o>",
    '<C-g>': "\<C-g>",
    '<C-e>': "\<C-e>",
    '<C-q>': "\<C-q>",
    '<C-d>': "\<C-d>",
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

  # Search option toggles
  if k ==# "\<C-r>" && (s_mode ==# 'grep' || s_mode ==# 'igrep')
    s_regex = !s_regex
    DispatchSearch()
    PanelRender()
    return true
  endif
  if k ==# "\<C-a>" && (s_mode ==# 'grep' || s_mode ==# 'igrep')
    # Cycle: smart -> ignore -> sensitive
    if s_case_mode ==# 'smart'
      s_case_mode = 'ignore'
    elseif s_case_mode ==# 'ignore'
      s_case_mode = 'sensitive'
    else
      s_case_mode = 'smart'
    endif
    DispatchSearch()
    PanelRender()
    return true
  endif
  if k ==# "\<C-o>"
    s_hidden = !s_hidden
    DispatchSearch()
    PanelRender()
    return true
  endif
  if k ==# "\<C-g>"
    s_no_ignore = !s_no_ignore
    DispatchSearch()
    PanelRender()
    return true
  endif
  if k ==# "\<C-e>"
    s_preview_on = !s_preview_on
    PreviewUpdate()
    return true
  endif
  if k ==# "\<C-q>"
    SendToQuickfix()
    return true
  endif
  if k ==# "\<C-d>" && s_mode ==# 'buffers'
    DeleteCurrentBuffer()
    return true
  endif

  # Multi-select: mark and move
  if k ==# "\<Tab>"
    if !empty(s_items) && s_cursor_idx < len(s_items)
      ToggleMark(s_cursor_idx)
      if s_cursor_idx < len(s_items) - 1
        s_cursor_idx += 1
      endif
      PanelRender()
    endif
    return true
  endif
  if k ==# "\<S-Tab>"
    if !empty(s_items) && s_cursor_idx < len(s_items)
      ToggleMark(s_cursor_idx)
      if s_cursor_idx > 0
        s_cursor_idx -= 1
      endif
      PanelRender()
    endif
    return true
  endif

  # Navigation
  if k ==# "\<C-j>" || k ==# "\<C-n>" || k ==# "\<Down>"
    if s_cursor_idx < len(s_items) - 1
      var old = s_cursor_idx
      s_cursor_idx += 1
      PanelMoveCursor(old, s_cursor_idx)
    endif
    return true
  endif
  if k ==# "\<C-k>" || k ==# "\<C-p>" || k ==# "\<Up>"
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
  s_loading = true
  s_error = ''
  PanelRender()
  Send({
    type: 'files',
    id: id,
    root: s_project_root,
    query: query,
    max: get(g:, 'simplefinder_max_results', 200),
    hidden: s_hidden,
    no_ignore: s_no_ignore,
  })
enddef

def SendGrepRequest(pattern: string)
  if pattern ==# ''
    if s_current_id > 0
      Send({type: 'cancel', id: s_current_id})
    endif
    s_current_id = 0
    s_items = []
    s_total = 0
    s_loading = false
    s_error = ''
    s_capped = false
    s_elapsed_ms = 0
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
  s_loading = true
  s_error = ''
  PanelRender()
  # smart: case-insensitive unless the pattern contains an uppercase letter
  var eff_ignore_case = s_case_mode ==# 'ignore'
    || (s_case_mode ==# 'smart' && match(pattern, '\u') < 0)
  Send({
    type: 'grep',
    id: id,
    root: s_project_root,
    pattern: pattern,
    regex: s_regex,
    ignore_case: eff_ignore_case,
    max: get(g:, 'simplefinder_max_results', 200),
    hidden: s_hidden,
    no_ignore: s_no_ignore,
  })
enddef

# =============================================================
# Multi-select & quickfix
# =============================================================

def ToggleMark(idx: number)
  var key = string(idx)
  if has_key(s_marked, key)
    remove(s_marked, key)
  else
    s_marked[key] = true
  endif
enddef

# Resolve an item's path against the project root when relative.
def ResolvePath(item: dict<any>): string
  var path = get(item, 'path', '')
  if (s_mode ==# 'files' || s_mode ==# 'grep' || s_mode ==# 'igrep') && s_project_root !=# ''
    if path !=# '' && path[0] !=# '/' && path[0] !=# '~'
      return s_project_root .. '/' .. path
    endif
  endif
  return path
enddef

# Send marked items (or all items when none are marked) to the quickfix list.
def SendToQuickfix()
  if empty(s_items)
    return
  endif
  var idxs: list<number> = []
  if !empty(s_marked)
    for key in keys(s_marked)
      var i = str2nr(key)
      if i >= 0 && i < len(s_items)
        add(idxs, i)
      endif
    endfor
    sort(idxs, 'n')
  else
    idxs = range(len(s_items))
  endif

  var qf: list<dict<any>> = []
  for i in idxs
    var item = s_items[i]
    var entry: dict<any> = {filename: ResolvePath(item)}
    if get(item, 'lnum', 0) > 0
      entry.lnum = item.lnum
      entry.col = max([1, get(item, 'col', 1)])
      entry.text = get(item, 'text', '')
    endif
    add(qf, entry)
  endfor
  if empty(qf)
    return
  endif

  var title = 'SimpleFinder ' .. s_mode .. (s_query ==# '' ? '' : ': ' .. s_query)
  setqflist([], ' ', {title: title, items: qf})
  PanelClose()
  copen
enddef

def DeleteCurrentBuffer()
  if empty(s_items) || s_cursor_idx >= len(s_items)
    return
  endif
  var bufnr = get(s_items[s_cursor_idx], 'bufnr', -1)
  if bufnr <= 0
    return
  endif
  try
    execute 'bdelete ' .. bufnr
  catch
    s_error = 'Cannot delete buffer ' .. bufnr .. ' (unsaved changes?)'
    PanelRender()
    return
  endtry
  s_error = ''
  filter(s_all_buffers, (_, v) => v.bufnr != bufnr)
  FilterBuffers()
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

# Re-open the panel exactly as it was last closed (mode, query, options).
export def Resume()
  if !s_has_session || s_mode ==# ''
    Files('')
    return
  endif
  var mode = s_mode
  var query = s_query
  if mode ==# 'buffers'
    Buffers()
    s_query = query
    FilterBuffers()
    return
  endif
  if mode ==# 'recent'
    RecentFiles()
    s_query = query
    FilterRecentFiles()
    return
  endif
  PanelOpen(mode, query, true)
  if mode ==# 'files' || query !=# ''
    DispatchSearch()
  endif
enddef

export def ProjectRoot(path: string = '')
  if path ==# ''
    echom '[SimpleFinder] root: ' .. FindProjectRoot()
    return
  endif
  var root = fnamemodify(expand(path), ':p')
  if !isdirectory(root)
    echohl ErrorMsg
    echom '[SimpleFinder] not a directory: ' .. path
    echohl None
    return
  endif
  g:simplefinder_root = substitute(root, '/$', '', '')
  echom '[SimpleFinder] root: ' .. g:simplefinder_root
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
  s_items = FuzzyFilterLocal(s_all_buffers, s_query)
  s_total = len(s_items)
  s_cursor_idx = 0
  s_scroll_off = 0
  s_marked = {}
  PanelRender()
enddef

# Fuzzy-filter a local item list on its `path` field, attaching match
# positions (char indices) as `indices` for highlighting.
def FuzzyFilterLocal(all: list<dict<any>>, query: string): list<dict<any>>
  if query ==# ''
    return mapnew(all, (_, v) => extendnew(v, {indices: []}))
  endif
  var by_path: dict<any> = {}
  for it in all
    by_path[it.path] = it
  endfor
  var paths = mapnew(all, (_, v) => v.path)
  var res = matchfuzzypos(paths, query)
  var out: list<dict<any>> = []
  for pi in range(len(res[0]))
    var mp = res[0][pi]
    if has_key(by_path, mp)
      add(out, extendnew(by_path[mp], {indices: res[1][pi]}))
    endif
  endfor
  return out
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
  s_items = FuzzyFilterLocal(s_all_recent, s_query)
  s_total = len(s_items)
  s_cursor_idx = 0
  s_scroll_off = 0
  s_marked = {}
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
  var path = ResolvePath(item)
  var lnum = get(item, 'lnum', 0)
  var col = get(item, 'col', 0)

  if get(g:, 'simplefinder_close_on_select', 1) != 0
    PanelClose()
  elseif s_source_winid > 0 && win_id2win(s_source_winid) > 0
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
    win_execute(s_panel_winid, 'normal! ' .. (s_cursor_idx - s_scroll_off + 4) .. 'G')
  endif
enddef

export def Reflow()
  if s_panel_winid > 0 && win_id2win(s_panel_winid) > 0
    PanelRender()
  endif
enddef
