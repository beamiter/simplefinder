vim9script

# =============================================================
# SimpleFinder — fuzzy finder & grep (Vim9 + Rust daemon)
# =============================================================

# ─────────────────── Daemon state ───────────────────

var s_job: any = v:null
var s_running: bool = false
var s_next_id: number = 0

# ─────────────────── Popup state ───────────────────

var s_popup_id: number = 0
var s_popup_bufnr: number = -1
var s_mode: string = ''          # 'files' | 'grep' | 'igrep' | 'recent' | 'buffers'
var s_query: string = ''
var s_items: list<dict<any>> = []
var s_cursor_idx: number = 0
var s_total: number = 0
var s_current_id: number = 0
var s_debounce_timer: number = 0
var s_project_root: string = ''

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
  PopupRender()
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
  PopupRender()
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
# Popup UI
# =============================================================

def PopupOpen(mode: string, initial_query: string = '')
  # Close existing popup first
  if s_popup_id > 0
    PopupClose()
  endif

  s_mode = mode
  s_query = initial_query
  s_items = []
  s_cursor_idx = 0
  s_total = 0
  s_current_id = 0
  s_project_root = FindProjectRoot()

  var width = get(g:, 'simplefinder_popup_width', 80)
  var height = get(g:, 'simplefinder_popup_height', 20)

  # Create an empty buffer for the popup
  s_popup_bufnr = bufadd('')
  bufload(s_popup_bufnr)
  setbufvar(s_popup_bufnr, '&buftype', 'nofile')
  setbufvar(s_popup_bufnr, '&bufhidden', 'wipe')
  setbufvar(s_popup_bufnr, '&buflisted', 0)
  setbufvar(s_popup_bufnr, '&swapfile', 0)

  s_popup_id = popup_create(s_popup_bufnr, {
    pos: 'center',
    minwidth: width,
    maxwidth: width,
    minheight: height,
    maxheight: height,
    border: [],
    borderchars: ['─', '│', '─', '│', '╭', '╮', '╰', '╯'],
    borderhighlight: ['SFinderBorder'],
    highlight: 'Normal',
    padding: [0, 1, 0, 1],
    scrollbar: 0,
    filter: function('PopupFilter'),
    callback: function('PopupOnClose'),
    mapping: 0,
    zindex: 200,
  })

  SetupSyntax()
  PopupRender()
enddef

def PopupClose()
  if s_debounce_timer > 0
    timer_stop(s_debounce_timer)
    s_debounce_timer = 0
  endif
  # Cancel running request
  if s_current_id > 0 && s_running
    Send({type: 'cancel', id: s_current_id})
    s_current_id = 0
  endif
  if s_popup_id > 0
    popup_close(s_popup_id)
    s_popup_id = 0
  endif
  s_popup_bufnr = -1
enddef

def PopupOnClose(id: number, result: any)
  s_popup_id = 0
  s_popup_bufnr = -1
enddef

def PopupRender()
  if s_popup_id == 0 || s_popup_bufnr < 0
    return
  endif

  var width = get(g:, 'simplefinder_popup_width', 80)
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
  var pad = width - strchars(title_line) - strchars(count_str) - 2
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
  var height = get(g:, 'simplefinder_popup_height', 20)
  var max_items = height - 4  # title + input + sep + help
  if max_items < 1
    max_items = 1
  endif

  # Scrolling: ensure cursor is visible
  var scroll_off = 0
  if s_cursor_idx >= max_items
    scroll_off = s_cursor_idx - max_items + 1
  endif

  var display_count = 0
  var idx = scroll_off
  while display_count < max_items && idx < len(s_items)
    var item = s_items[idx]
    var line = ''
    var marker = idx == s_cursor_idx ? "\u25b8 " : '  '

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

    # Truncate if too long
    if strchars(line) > width
      line = strcharpart(line, 0, width - 1) .. "\u2026"
    endif
    add(lines, line)
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

  # Write to buffer
  setbufline(s_popup_bufnr, 1, lines)
  # Remove extra lines if buffer had more before
  var buflines = getbufline(s_popup_bufnr, 1, '$')
  if len(buflines) > len(lines)
    deletebufline(s_popup_bufnr, len(lines) + 1, '$')
  endif

  # Refresh popup
  if s_popup_id > 0
    popup_settext(s_popup_id, lines)
  endif
enddef

def SetupSyntax()
  if s_popup_id == 0
    return
  endif
  win_execute(s_popup_id, 'syntax clear')
  win_execute(s_popup_id, 'syntax match SFinderTitle /^ .\+ \(Files\|Grep\|Interactive Grep\|Recent Files\|Buffers\)/')
  win_execute(s_popup_id, 'syntax match SFinderStatus /\d\+ results$/')
  win_execute(s_popup_id, 'syntax match SFinderPrompt /^ > /')
  win_execute(s_popup_id, 'syntax match SFinderSep /^─\+$/')
  win_execute(s_popup_id, 'syntax match SFinderLnum /:\d\+:/')
  win_execute(s_popup_id, 'syntax match SFinderStatus /^ .\+ open.*esc close$/')
  # Selected item (line starting with triangle marker)
  win_execute(s_popup_id, 'syntax match SFinderSelected /^\%u25b8 .*$/')
  win_execute(s_popup_id, 'setlocal cursorline!')
enddef

# ─────────────────── Filter callback ───────────────────

def PopupFilter(winid: number, key: string): bool
  if key ==# "\<Esc>" || key ==# "\<C-c>"
    PopupClose()
    return true
  endif

  if key ==# "\<CR>"
    AcceptItem('edit')
    return true
  endif
  if key ==# "\<C-v>"
    AcceptItem('vsplit')
    return true
  endif
  if key ==# "\<C-x>" || key ==# "\<C-s>"
    AcceptItem('split')
    return true
  endif
  if key ==# "\<C-t>"
    AcceptItem('tabedit')
    return true
  endif

  # Navigation
  if key ==# "\<C-j>" || key ==# "\<C-n>" || key ==# "\<Down>" || key ==# "\<Tab>"
    if s_cursor_idx < len(s_items) - 1
      s_cursor_idx += 1
      PopupRender()
    endif
    return true
  endif
  if key ==# "\<C-k>" || key ==# "\<C-p>" || key ==# "\<Up>" || key ==# "\<S-Tab>"
    if s_cursor_idx > 0
      s_cursor_idx -= 1
      PopupRender()
    endif
    return true
  endif

  # Editing
  if key ==# "\<BS>" || key ==# "\<C-h>"
    if len(s_query) > 0
      s_query = strcharpart(s_query, 0, strchars(s_query) - 1)
      DebouncedSearch()
      PopupRender()
    endif
    return true
  endif
  if key ==# "\<C-u>"
    s_query = ''
    DebouncedSearch()
    PopupRender()
    return true
  endif
  if key ==# "\<C-w>"
    # Delete last word
    s_query = substitute(s_query, '\S*\s*$', '', '')
    DebouncedSearch()
    PopupRender()
    return true
  endif

  # Printable character
  if strlen(key) == 1 && char2nr(key) >= 32
    s_query ..= key
    DebouncedSearch()
    PopupRender()
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
    PopupRender()
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
  PopupOpen('files', query)
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
  PopupOpen('grep', p)
  SendGrepRequest(p)
enddef

export def IGrep(initial: string = '')
  PopupOpen('igrep', initial)
  if initial !=# ''
    SendGrepRequest(initial)
  endif
enddef

export def GrepWord()
  var word = expand('<cword>')
  if word !=# ''
    PopupOpen('igrep', word)
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
    PopupOpen('igrep', text)
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
  PopupOpen('buffers')
  s_items = copy(s_all_buffers)
  s_total = len(s_items)
  PopupRender()
enddef

def FilterBuffers()
  if s_query ==# ''
    s_items = copy(s_all_buffers)
  else
    s_items = []
    var paths = mapnew(s_all_buffers, (_, v) => v.path)
    var matched = matchfuzzy(paths, s_query)
    for mp in matched
      for buf in s_all_buffers
        if buf.path ==# mp
          add(s_items, buf)
          break
        endif
      endfor
    endfor
  endif
  s_total = len(s_items)
  s_cursor_idx = 0
  PopupRender()
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
  PopupOpen('recent')
  s_items = copy(s_all_recent)
  s_total = len(s_items)
  PopupRender()
enddef

def FilterRecentFiles()
  if s_query ==# ''
    s_items = copy(s_all_recent)
  else
    s_items = []
    var paths = mapnew(s_all_recent, (_, v) => v.path)
    var matched = matchfuzzy(paths, s_query)
    for mp in matched
      for item in s_all_recent
        if item.path ==# mp
          add(s_items, item)
          break
        endif
      endfor
    endfor
  endif
  s_total = len(s_items)
  s_cursor_idx = 0
  PopupRender()
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

  PopupClose()

  # For files/grep results, resolve relative path from project root
  if (s_mode ==# 'files' || s_mode ==# 'grep' || s_mode ==# 'igrep') && s_project_root !=# ''
    if path[0] !=# '/' && path[0] !=# '~'
      path = s_project_root .. '/' .. path
    endif
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
enddef
