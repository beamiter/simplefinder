vim9script

# =============================================================
# SimpleFinder — fuzzy finder & grep (Vim9 + Rust daemon)
# =============================================================


# ─────────────────── Daemon state ───────────────────
#
# Process lifecycle (start, restart, backoff, liveness, request timeouts) is
# owned by the vendored simplecore supervisor; only the request bookkeeping
# below is SimpleFinder's own.

var s_next_id: number = 0

# ─────────────────── Panel state ───────────────────

var s_panel_winid: number = 0
var s_panel_bufnr: number = -1
var s_source_winid: number = 0
var s_source_bufnr: number = 0
var s_mode: string = ''          # 'files' | 'gitfiles' | 'grep' | 'igrep' | 'symbols' | 'recent' | 'buffers' | 'lines' | 'help'
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
var s_marked: dict<bool> = {}       # stable item identity -> marked
var s_marked_items: dict<dict<any>> = {} # complete snapshots, including hidden marks
var s_mark_order: list<string> = [] # first-mark order, independent of result sorting
var s_preview_on: bool = false
var s_preview_winid: number = 0
var s_has_session: bool = false     # a search was opened before (for Resume)
var s_include_globs: list<string> = []
var s_exclude_globs: list<string> = []
var s_glob_error: string = ''

# ─────────────────── Recent files ───────────────────

var s_recent_files: list<string> = []

# ─────────────────── Logging ───────────────────

def Log(msg: string)
  simplefinder#core#Log(msg)
enddef

# =============================================================
# Daemon communication layer
#
# The supervisor owns the process; this file only decides what to send and
# what to do with what comes back.
# =============================================================

var s_core_ready: bool = false

def SetupCore()
  if s_core_ready
    return
  endif
  s_core_ready = true
  simplefinder#core#Setup({
    name: 'SimpleFinder',
    exe: 'simplefinder-daemon',
    path_var: 'simplefinder_daemon_path',
    debug_var: 'simplefinder_debug',
    handshake: {request: {type: 'ping'}, reply_type: 'pong'},
    OnEvent: OnDaemonEvent,
    OnExit: OnDaemonExit,
  })
enddef

def EnsureBackend(): bool
  SetupCore()
  return simplefinder#core#Ensure()
enddef

def Send(req: dict<any>): bool
  return simplefinder#core#Send(req)
enddef

def NextId(): number
  s_next_id += 1
  return s_next_id
enddef

# A daemon that dies mid-search must not leave the panel spinning forever.
def OnDaemonExit(code: number, restarting: bool)
  if s_current_id <= 0
    return
  endif
  s_loading = false
  s_current_id = 0
  s_error = restarting
    ? printf('Backend exited (code %d); restarting…', code)
    : printf('Backend exited unexpectedly (code %d)', code)
  PanelRender()
enddef

def OnDaemonEvent(ev: dict<any>)
  if !has_key(ev, 'type')
    return
  endif

  # The handshake reply is bookkeeping, not a search result.  A configured
  # filter must fail closed with an old daemon instead of silently searching
  # paths the user explicitly excluded.
  if ev.type ==# 'pong'
    if (!empty(s_include_globs) || !empty(s_exclude_globs))
        && !get(get(ev, 'capabilities', {}), 'path_globs', false)
      if s_current_id > 0
        Send({type: 'cancel', id: s_current_id})
      endif
      s_current_id = 0
      s_loading = false
      s_error = 'backend lacks path-glob support; rerun ./install.sh'
      PanelRender()
    endif
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
  SetupCore()
  simplefinder#core#Stop()
enddef

export def Restart()
  SetupCore()
  if simplefinder#core#Restart()
    echom '[SimpleFinder] daemon restarted'
  endif
enddef

export def ShowLog()
  simplefinder#core#ShowLog()
enddef

export def Health()
  SetupCore()
  var lines = ['SimpleFinder health', repeat('─', 40)]
  extend(lines, simplefinder#core#HealthLines())
  var caps = simplefinder#core#Caps()
  if simplefinder#core#Ready() && empty(caps)
    add(lines, '[WARN] daemon predates the capability handshake; rerun ./install.sh')
  endif
  add(lines, printf('[%s] popup preview: %s',
    has('popupwin') ? 'OK' : 'WARN',
    has('popupwin') ? 'available' : 'missing +popupwin — preview disabled'))
  add(lines, printf('[INFO] project root: %s',
    s_project_root ==# '' ? '(not resolved yet)' : s_project_root))
  try
    var includes = ReadPathGlobList('simplefinder_include_globs')
    var excludes = ReadPathGlobList('simplefinder_exclude_globs')
    add(lines, printf('[INFO] path globs: %d include, %d exclude',
      len(includes), len(excludes)))
  catch
    add(lines, '[WARN] path globs: ' .. v:exception)
  endtry
  for line in lines
    echom line
  endfor
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

def ReadPathGlobList(option: string): list<string>
  var configured = get(g:, option, [])
  if type(configured) != v:t_list
    throw option .. ' must be a list of strings'
  endif
  var result: list<string> = []
  for value in configured
    if type(value) != v:t_string || value ==# ''
      throw option .. ' must contain only non-empty strings'
    endif
    if value[0] ==# '!'
      throw option .. ' entries must not start with !; use the separate exclude option'
    endif
    add(result, value)
  endfor
  return result
enddef

def SnapshotPathGlobs(mode: string)
  s_include_globs = []
  s_exclude_globs = []
  s_glob_error = ''
  if index(['files', 'grep', 'igrep', 'symbols'], mode) < 0
    return
  endif
  try
    s_include_globs = ReadPathGlobList('simplefinder_include_globs')
    s_exclude_globs = ReadPathGlobList('simplefinder_exclude_globs')
  catch
    s_include_globs = []
    s_exclude_globs = []
    s_glob_error = v:exception
  endtry
enddef

def PathGlobsReady(): bool
  if s_glob_error !=# ''
    s_loading = false
    s_error = s_glob_error
    PanelRender()
    return false
  endif
  if (!empty(s_include_globs) || !empty(s_exclude_globs))
      && simplefinder#core#Ready() && !simplefinder#core#HasCap('path_globs')
    s_loading = false
    s_error = 'backend lacks path-glob support; rerun ./install.sh'
    PanelRender()
    return false
  endif
  return true
enddef

# =============================================================
# Panel UI
# =============================================================

def PanelOpen(mode: string, initial_query: string = '', keep_options: bool = false)
  # Editing another file into the old panel window makes that window the new
  # source just as surely as closing/reopening the panel does.
  if s_panel_winid <= 0 || win_id2win(s_panel_winid) == 0
      || winbufnr(s_panel_winid) != s_panel_bufnr
    s_source_winid = win_getid()
    s_source_bufnr = bufnr('%')
  elseif win_getid() != s_panel_winid
    s_source_winid = win_getid()
    s_source_bufnr = bufnr('%')
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
  s_marked_items = {}
  s_mark_order = []
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
    SnapshotPathGlobs(mode)
  endif
  if s_glob_error !=# ''
    s_error = s_glob_error
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

  # The tracked window must still display the panel buffer; the user may
  # have :edit-ed another file into it.
  if s_panel_winid <= 0 || win_id2win(s_panel_winid) == 0
      || winbufnr(s_panel_winid) != s_panel_bufnr
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
  if s_current_id > 0
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
  # A closed panel owns no selectable state. Resume restores the search, not a
  # hidden selection that can unexpectedly populate a later quickfix list.
  s_marked = {}
  s_marked_items = {}
  s_mark_order = []
enddef

def ItemIdentityBase(item: dict<any>): string
  # Include every field that makes a result independently actionable. The
  # display score/highlight indices are intentionally excluded so a new query
  # can reorder/re-score an otherwise identical result without losing marks.
  return string([
    get(item, 'path', ''),
    get(item, 'bufnr', -1),
    get(item, 'lnum', 0),
    get(item, 'col', 0),
    get(item, 'col_end', 0),
    get(item, 'text', ''),
  ])
enddef

def AssignItemIdentities(items: list<dict<any>>)
  var needs_ids = false
  for item in items
    if type(get(item, '_simplefinder_mark_id', v:null)) != v:t_string
      needs_ids = true
      break
    endif
  endfor
  if !needs_ids
    return
  endif
  var occurrences: dict<number> = {}
  for item in items
    var base = ItemIdentityBase(item)
    var occurrence = get(occurrences, base, 0) + 1
    occurrences[base] = occurrence
    item._simplefinder_mark_id = base .. '#' .. string(occurrence)
  endfor
enddef

def ItemIdentity(item: dict<any>): string
  var identity = get(item, '_simplefinder_mark_id', '')
  return type(identity) == v:t_string ? identity : ''
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
  AssignItemIdentities(s_items)

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
    lines: 'Buffer Lines',
    help: 'Help Tags',
    gitfiles: 'Git Files',
    symbols: 'Symbols',
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
  if !empty(s_mark_order)
    count_str = string(len(s_mark_order)) .. ' marked · ' .. count_str
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
  if !empty(s_include_globs) || !empty(s_exclude_globs)
    flags ..= printf(' [glob +%d/-%d]', len(s_include_globs), len(s_exclude_globs))
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
  var help = " \u23ce open  \u21e5 mark  ^q qf  ^l loclist  ^e preview  esc close"
  if s_error !=# '' && !empty(s_items)
    help = ' ! ' .. s_error
  elseif s_mode ==# 'grep' || s_mode ==# 'igrep'
    help = ' ^r regex  ^a case  ^o hidden  ^g ignores  ^q qf  ^l loc'
  elseif s_mode ==# 'buffers'
    help = " \u23ce open  \u21e5 mark  ^d bdelete  ^q qf  ^l loc  esc close"
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
  var identity = idx >= 0 && idx < len(s_items) ? ItemIdentity(s_items[idx]) : ''
  var mark_ch = identity !=# '' && has_key(s_marked, identity) ? '*' : ' '
  return cursor_ch .. mark_ch .. ' '
enddef

def FormatItemLine(idx: number, width: number): string
  var item = s_items[idx]
  var marker = ItemMarker(idx)
  var line = ''

  if s_mode ==# 'files' || s_mode ==# 'recent' || s_mode ==# 'gitfiles'
    line = marker .. get(item, 'path', '')
  elseif s_mode ==# 'grep' || s_mode ==# 'igrep' || s_mode ==# 'symbols'
    var path = get(item, 'path', '')
    var lnum = get(item, 'lnum', 0)
    var text = get(item, 'text', '')
    line = marker .. path .. ':' .. string(lnum) .. ': ' .. text
  elseif s_mode ==# 'buffers'
    var path = get(item, 'path', '')
    var mod = get(item, 'modified', 0) ? ' [+]' : ''
    line = marker .. path .. mod
  elseif s_mode ==# 'lines'
    line = marker .. string(get(item, 'lnum', 0)) .. ': ' .. get(item, 'text', '')
  elseif s_mode ==# 'help'
    line = marker .. get(item, 'path', '')
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
    if s_mode ==# 'grep' || s_mode ==# 'igrep' || s_mode ==# 'symbols'
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
      # Char offset of the matched field within the rendered row.
      var prefix_chars = 3
      if s_mode ==# 'lines'
        prefix_chars = 3 + strchars(string(get(item, 'lnum', 0)) .. ': ')
      endif
      for i in get(item, 'indices', [])
        var ci = prefix_chars + i
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
  nnoremap <silent><buffer> <C-l> <ScriptCmd>PanelHandleKey(0, '<lt>C-l>')<CR>
  nnoremap <silent><buffer> <C-d> <ScriptCmd>PanelHandleKey(0, '<lt>C-d>')<CR>

  # Map the complete printable ASCII range, including regex punctuation.
  for code in range(32, 126)
    execute 'nnoremap <silent><buffer> <Char-' .. code .. '> <ScriptCmd>PanelHandleChar(' .. code .. ')<CR>'
  endfor
enddef

# ─────────────────── Panel key handling ───────────────────

def PanelHandleKey(winid: number, key: string): bool
  # :wincmd T recreates the window with a new ID while keeping this buffer and
  # its mappings. Rebind before rendering/closing so follow-up keys never act
  # through a stale panel handle.
  var active_winid = winid > 0 ? winid : win_getid()
  if s_panel_bufnr > 0 && winbufnr(active_winid) == s_panel_bufnr
    s_panel_winid = active_winid
  endif
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
    '<C-l>': "\<C-l>",
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
    SendToList(false)
    return true
  endif
  if k ==# "\<C-l>"
    SendToList(true)
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
  elseif s_mode ==# 'symbols'
    SendSymbolRequest(s_query)
  elseif s_mode ==# 'buffers'
    FilterBuffers()
  elseif s_mode ==# 'recent'
    FilterRecentFiles()
  elseif s_mode ==# 'lines'
    FilterLines()
  elseif s_mode ==# 'help'
    FilterHelp()
  elseif s_mode ==# 'gitfiles'
    FilterGitFiles()
  endif
enddef

# =============================================================
# Search functions — daemon-based
# =============================================================

def SendFilesRequest(query: string)
  if !PathGlobsReady()
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
  Send({
    type: 'files',
    id: id,
    root: s_project_root,
    query: query,
    max: get(g:, 'simplefinder_max_results', 200),
    hidden: s_hidden,
    no_ignore: s_no_ignore,
    include_globs: s_include_globs,
    exclude_globs: s_exclude_globs,
  })
enddef

def SendGrepRequest(pattern: string)
  if !PathGlobsReady()
    return
  endif
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
    include_globs: s_include_globs,
    exclude_globs: s_exclude_globs,
  })
enddef

# =============================================================
# Multi-select & quickfix/location lists
# =============================================================

def ToggleMark(idx: number)
  if idx < 0 || idx >= len(s_items)
    return
  endif
  AssignItemIdentities(s_items)
  var item = s_items[idx]
  var key = ItemIdentity(item)
  if key ==# ''
    return
  endif
  if has_key(s_marked, key)
    remove(s_marked, key)
    if has_key(s_marked_items, key)
      remove(s_marked_items, key)
    endif
    filter(s_mark_order, (_, identity) => identity !=# key)
  else
    s_marked[key] = true
    s_marked_items[key] = deepcopy(item)
    add(s_mark_order, key)
  endif
enddef

# Resolve an item's path against the project root when relative.
def ResolvePath(item: dict<any>): string
  var path = get(item, 'path', '')
  if s_mode ==# 'gitfiles' && s_git_root !=# ''
    if path !=# '' && path[0] !=# '/' && path[0] !=# '~'
      return s_git_root .. '/' .. path
    endif
    return path
  endif
  if (s_mode ==# 'files' || s_mode ==# 'grep' || s_mode ==# 'igrep'
      || s_mode ==# 'symbols') && s_project_root !=# ''
    if path !=# '' && path[0] !=# '/' && path[0] !=# '~'
      return s_project_root .. '/' .. path
    endif
  endif
  return path
enddef

# Send marked items (or all items when none are marked) to quickfix, or to the
# location list owned by the exact window+buffer that launched the panel.
def SendToList(location: bool)
  if empty(s_items) && empty(s_mark_order)
    return
  endif
  var selected: list<dict<any>> = []
  if !empty(s_mark_order)
    for key in s_mark_order
      if has_key(s_marked_items, key)
        add(selected, s_marked_items[key])
      endif
    endfor
  else
    selected = s_items
  endif

  var qf: list<dict<any>> = []
  for item in selected
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
  if location
    var source_info = getwininfo(s_source_winid)
    if len(source_info) != 1 || get(source_info[0], 'bufnr', -1) != s_source_bufnr
      s_error = 'source window changed buffer; location list not updated'
      PanelRender()
      return
    endif
    if get(source_info[0], 'tabnr', -1) != tabpagenr()
      s_error = 'source window is in another tab; location list not updated'
      PanelRender()
      return
    endif
    # setloclist() accepts a stable window ID, so no temporary win_gotoid()
    # can leak events or edit the wrong split.
    if setloclist(s_source_winid, [], ' ', {title: title, items: qf}) != 0
      s_error = 'could not update source location list'
      PanelRender()
      return
    endif
    PanelClose()
    lopen
  else
    setqflist([], ' ', {title: title, items: qf})
    PanelClose()
    copen
  endif
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

# Exclusive byte offset at which an inclusive selection ending on byte `col`
# stops.  `$` reports one past the last byte, and with 'selection' inclusive
# `col` addresses the *first* byte of the character under the cursor, so a
# naive `strpart(line, 0, col)` cuts multi-byte characters in half.
def SelectionEnd(line: string, col: number): number
  if &selection ==# 'exclusive'
    return col - 1
  endif
  if col > len(line)
    return len(line)
  endif
  return col - 1 + strlen(matchstr(line, '.', col - 1))
enddef

# Text of the region a Visual-mode invocation is really about.
#
# A `<Cmd>` mapping — the form the README and the help teach — runs while
# Visual mode is still active, and Vim only writes the '< and '> marks when
# the selection *ends*.  Inside the mapping those marks therefore still
# describe the previous selection (:help <Cmd>), which is why every grep
# searched one selection behind and the first of a session searched nothing.
# `v` (the anchor) and `.` (the cursor) hold the live region, so read those
# whenever a Visual (or Select) mode is actually current, and fall back to the
# marks for `:'<,'>SimpleFinderGrepVisual`, where no Visual mode is left.
def VisualRegionText(): string
  # mode() spells Select mode with s/S/<C-s>; the geometry is identical.
  var live = strpart(mode(), 0, 1)
  var kind = {s: 'v', S: 'V', ["\<C-s>"]: "\<C-v>"}->get(live, live)
  var start: list<number>
  var finish: list<number>
  if kind ==# 'v' || kind ==# 'V' || kind ==# "\<C-v>"
    start = getpos('v')
    finish = getpos('.')
  else
    kind = visualmode()
    start = getpos("'<")
    finish = getpos("'>")
  endif
  if start[1] <= 0 || finish[1] <= 0
    return ''
  endif
  # The cursor may sit at either end of the selection.
  if start[1] > finish[1] || (start[1] == finish[1] && start[2] > finish[2])
    [start, finish] = [finish, start]
  endif

  var lines = getline(start[1], finish[1])
  if empty(lines)
    return ''
  endif
  if kind ==# 'V'
    # Linewise: whole lines, whatever the columns happen to say.
  elseif kind ==# "\<C-v>"
    var left = min([start[2], finish[2]])
    var right = max([start[2], finish[2]])
    map(lines, (_, l) => strpart(l, left - 1, SelectionEnd(l, right) - left + 1))
  elseif len(lines) == 1
    lines[0] = strpart(lines[0], start[2] - 1,
      SelectionEnd(lines[0], finish[2]) - start[2] + 1)
  else
    lines[0] = strpart(lines[0], start[2] - 1)
    lines[-1] = strpart(lines[-1], 0, SelectionEnd(lines[-1], finish[2]))
  endif
  return join(lines, ' ')
enddef

export def GrepVisual()
  var text = VisualRegionText()
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
  if mode ==# 'lines'
    Lines()
    s_query = query
    FilterLines()
    return
  endif
  if mode ==# 'help'
    HelpTags()
    s_query = query
    FilterHelp()
    return
  endif
  if mode ==# 'gitfiles'
    GitFiles()
    s_query = query
    FilterGitFiles()
    return
  endif
  PanelOpen(mode, query, true)
  if mode ==# 'files' || mode ==# 'symbols' || query !=# ''
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
  AssignItemIdentities(s_all_buffers)
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
  PanelRender()
enddef

# =============================================================
# Buffer lines (pure Vim9)
# =============================================================

var s_all_lines: list<dict<any>> = []

export def Lines()
  var src_buf = bufnr('%')
  var src_name = fnamemodify(bufname(src_buf), ':~:.')
  var mx = get(g:, 'simplefinder_lines_max', 50000)
  s_all_lines = []
  var ln = 0
  for text in getline(1, '$')
    ln += 1
    if trim(text) ==# ''
      continue
    endif
    add(s_all_lines, {path: src_name, bufnr: src_buf, lnum: ln, text: text})
    if len(s_all_lines) >= mx
      break
    endif
  endfor
  AssignItemIdentities(s_all_lines)
  PanelOpen('lines')
  s_items = copy(s_all_lines)
  s_total = len(s_items)
  PanelRender()
enddef

def FilterLines()
  s_items = FuzzyFilterLocal(s_all_lines, s_query, 'text')
  s_total = len(s_items)
  s_cursor_idx = 0
  s_scroll_off = 0
  PanelRender()
enddef

# =============================================================
# Help tags (pure Vim9)
# =============================================================

var s_all_help: list<dict<any>> = []

export def HelpTags()
  s_all_help = []
  var seen: dict<bool> = {}
  for tagfile in globpath(&runtimepath, 'doc/tags', 0, 1)
    var lines: list<string> = []
    try
      lines = readfile(tagfile)
    catch
      continue
    endtry
    for tagline in lines
      var parts = split(tagline, "\t")
      if len(parts) >= 2 && !has_key(seen, parts[0])
        seen[parts[0]] = true
        add(s_all_help, {path: parts[0]})
      endif
    endfor
  endfor
  sort(s_all_help, (a, b) => a.path <# b.path ? -1 : a.path ==# b.path ? 0 : 1)
  AssignItemIdentities(s_all_help)
  PanelOpen('help')
  s_items = copy(s_all_help)
  s_total = len(s_items)
  PanelRender()
enddef

def FilterHelp()
  s_items = FuzzyFilterLocal(s_all_help, s_query)
  s_total = len(s_items)
  s_cursor_idx = 0
  s_scroll_off = 0
  PanelRender()
enddef

# Fuzzy-filter a local item list on `key`, attaching match positions
# (char indices) as `indices` for highlighting.
def FuzzyFilterLocal(all: list<dict<any>>, query: string, key = 'path'): list<dict<any>>
  if query ==# ''
    return mapnew(all, (_, v) => extendnew(v, {indices: []}))
  endif
  var res = matchfuzzypos(all, query, {key: key})
  var out: list<dict<any>> = []
  for pi in range(len(res[0]))
    add(out, extendnew(res[0][pi], {indices: res[1][pi]}))
  endfor
  return out
enddef

# =============================================================
# Symbols
#
# Project-wide definition search built on the grep the daemon already does.
# This deliberately has no language server or tags file behind it: SimpleFinder
# installs on its own, and a symbol search that only works once some other
# plugin is present is worse than one that always works. Matching definition
# lines by keyword is coarser than a real index, but it needs no setup, stays
# current with the file on disk, and searches 19k files in single-digit
# milliseconds.
# =============================================================

# filetype -> definition-introducing keywords. The regex is assembled from
# these, so adding a language is one entry.
var s_symbol_keywords: dict<list<string>> = {
  rust:       ['fn', 'struct', 'enum', 'trait', 'impl', 'type', 'const', 'static', 'macro_rules!', 'mod'],
  python:     ['def', 'class', 'async def'],
  javascript: ['function', 'class', 'const', 'let', 'var'],
  typescript: ['function', 'class', 'const', 'let', 'var', 'interface', 'type', 'enum'],
  javascriptreact: ['function', 'class', 'const', 'let', 'var'],
  typescriptreact: ['function', 'class', 'const', 'let', 'var', 'interface', 'type', 'enum'],
  go:         ['func', 'type', 'var', 'const'],
  c:          ['struct', 'enum', 'union', 'typedef', 'static', 'void', 'int', 'char', 'define'],
  cpp:        ['class', 'struct', 'enum', 'union', 'typedef', 'namespace', 'template', 'void', 'int', 'auto'],
  java:       ['class', 'interface', 'enum', 'void', 'public', 'private', 'protected', 'static'],
  ruby:       ['def', 'class', 'module'],
  lua:        ['function', 'local'],
  vim:        ['function', 'def', 'command', 'let', 'var', 'const'],
  sh:         ['function'],
  bash:       ['function'],
  zsh:        ['function'],
  haskell:    ['data', 'newtype', 'type', 'class', 'instance'],
  julia:      ['function', 'struct', 'macro', 'module', 'const'],
  php:        ['function', 'class', 'interface', 'trait'],
  cs:         ['class', 'interface', 'struct', 'enum', 'void', 'public', 'private'],
  kotlin:     ['fun', 'class', 'object', 'interface', 'val', 'var'],
  swift:      ['func', 'class', 'struct', 'enum', 'protocol', 'extension', 'let', 'var'],
  scala:      ['def', 'class', 'object', 'trait', 'val', 'var', 'type'],
}

# Used when the filetype is unknown, or deliberately, to search every language
# at once -- which is usually what you want in a polyglot repository.
def AllSymbolKeywords(): list<string>
  var seen: dict<bool> = {}
  var out: list<string> = []
  for [ft, words] in items(s_symbol_keywords)
    for w in words
      if !has_key(seen, w)
        seen[w] = true
        add(out, w)
      endif
    endfor
  endfor
  return out
enddef

# Resolved once, from the source buffer, before the panel opens. Reading
# &filetype later would see the panel's own buffer and silently fall back to
# every language at once.
var s_symbol_words: list<string> = []

def SymbolKeywordsFor(ft: string): list<string>
  var custom = get(g:, 'simplefinder_symbol_keywords', {})
  if type(custom) == v:t_dict && has_key(custom, ft) && type(custom[ft]) == v:t_list
    return custom[ft]
  endif
  if get(g:, 'simplefinder_symbol_all_languages', 0) || ft ==# ''
    return AllSymbolKeywords()
  endif
  return get(s_symbol_keywords, ft, AllSymbolKeywords())
enddef

# Escape the parts of a query that would otherwise be read as regex syntax.
# The keyword alternation around it is ours, so only the user's text is quoted.
def EscapeRegexLiteral(text: string): string
  return substitute(text, '[\\^$.*+?()\[\]{}|/]', '\\&', 'g')
enddef

def SymbolPattern(query: string): string
  var words = s_symbol_words
  if empty(words)
    return ''
  endif
  var alternation = join(mapnew(words, (_, w) => EscapeRegexLiteral(w)), '|')
  # A definition line: keyword, whitespace, then a name containing the query.
  # Leading (^|\s) keeps `fn` from matching inside another identifier.
  var name = query ==# '' ? '[A-Za-z_]' : '[A-Za-z0-9_]*' .. EscapeRegexLiteral(query)
  return '(^|[^A-Za-z0-9_])(' .. alternation .. ')[ \t]+[A-Za-z0-9_*&]*' .. name
enddef

def SendSymbolRequest(query: string)
  if !PathGlobsReady()
    return
  endif
  var pattern = SymbolPattern(query)
  if pattern ==# ''
    s_error = 'no symbol keywords for this filetype'
    s_loading = false
    PanelRender()
    return
  endif
  if !EnsureBackend()
    return
  endif
  if s_current_id > 0
    Send({type: 'cancel', id: s_current_id})
  endif
  var id = NextId()
  s_current_id = id
  s_loading = true
  s_error = ''
  PanelRender()
  # Always a regex, and always case-sensitive on the keyword half; smart-case
  # still applies to what the user typed.
  var eff_ignore_case = s_case_mode ==# 'ignore'
    || (s_case_mode ==# 'smart' && match(query, '\u') < 0 && query !=# '')
  Send({
    type: 'grep',
    id: id,
    root: s_project_root,
    pattern: pattern,
    regex: true,
    ignore_case: eff_ignore_case,
    max: get(g:, 'simplefinder_max_results', 200),
    hidden: s_hidden,
    no_ignore: s_no_ignore,
    include_globs: s_include_globs,
    exclude_globs: s_exclude_globs,
  })
enddef

export def Symbols(query: string = '')
  s_symbol_words = SymbolKeywordsFor(&filetype)
  PanelOpen('symbols', query)
  SendSymbolRequest(query)
enddef

# =============================================================
# Git files
#
# `git ls-files` is the fastest way to enumerate a large repository: it reads
# the index instead of walking the tree, and it already honours .gitignore,
# sparse checkouts and skip-worktree.  Untracked-but-not-ignored files are
# included so a newly created file is findable before it is staged.
# =============================================================

var s_all_gitfiles: list<dict<any>> = []
var s_git_root: string = ''

# systemlist() is typed as taking a string in Vim9, so argv is escaped here
# rather than passed as a list.
def ShellJoin(argv: list<string>): string
  return join(mapnew(argv, (_, a) => shellescape(a)), ' ')
enddef

def GitRootFor(dir: string): string
  if !executable('git')
    return ''
  endif
  var out = systemlist(ShellJoin(['git', '-C', dir, 'rev-parse', '--show-toplevel']))
  if v:shell_error != 0 || empty(out)
    return ''
  endif
  return substitute(out[0], '[\r\n]\+$', '', '')
enddef

export def GitFiles()
  var start = expand('%:p:h')
  if start ==# '' || !isdirectory(start)
    start = getcwd()
  endif
  var root = GitRootFor(start)
  if root ==# ''
    echohl WarningMsg
    echom executable('git')
      ? '[SimpleFinder] not inside a git repository'
      : '[SimpleFinder] git is not installed'
    echohl None
    return
  endif
  s_git_root = root

  # -c core.quotepath=false keeps non-ASCII names readable instead of
  # \303\251-style escapes.  --exclude-standard applies the usual ignore
  # rules to the untracked half, and --deduplicate keeps merge conflicts from
  # listing the same path three times.
  var out = systemlist(ShellJoin([
    'git', '-c', 'core.quotepath=false', '-C', root,
    'ls-files', '--cached', '--others', '--exclude-standard', '--deduplicate',
  ]))
  if v:shell_error != 0
    echohl ErrorMsg
    echom '[SimpleFinder] git ls-files failed: ' .. join(out[0 : 2], ' ')
    echohl None
    return
  endif

  s_all_gitfiles = []
  for f in out
    if f !=# ''
      add(s_all_gitfiles, {path: f})
    endif
  endfor
  AssignItemIdentities(s_all_gitfiles)
  PanelOpen('gitfiles')
  s_items = copy(s_all_gitfiles)
  s_total = len(s_items)
  PanelRender()
enddef

def FilterGitFiles()
  s_items = FuzzyFilterLocal(s_all_gitfiles, s_query)
  s_total = len(s_items)
  s_cursor_idx = 0
  s_scroll_off = 0
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
  AssignItemIdentities(s_all_recent)
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

  # Help tags open with :help instead of :edit.
  if s_mode ==# 'help'
    var tag = get(item, 'path', '')
    if get(g:, 'simplefinder_close_on_select', 1) != 0
      PanelClose()
    elseif s_source_winid > 0 && win_id2win(s_source_winid) > 0
      win_gotoid(s_source_winid)
    endif
    try
      execute 'help ' .. fnameescape(tag)
    catch
      echohl WarningMsg | echomsg 'simplefinder: ' .. v:exception | echohl None
    endtry
    return
  endif

  var path = ResolvePath(item)
  var lnum = get(item, 'lnum', 0)
  var col = get(item, 'col', 0)

  if get(g:, 'simplefinder_close_on_select', 1) != 0
    PanelClose()
  elseif s_source_winid > 0 && win_id2win(s_source_winid) > 0
    win_gotoid(s_source_winid)
  endif

  # For buffers and buffer lines, prefer bufnr so unnamed buffers work too.
  var bufnr = get(item, 'bufnr', -1)
  if bufnr > 0 && mode ==# 'edit'
    execute 'buffer ' .. bufnr
  elseif bufnr > 0
    execute mode
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
