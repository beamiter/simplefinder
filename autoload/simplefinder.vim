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
var s_query_cursor: number = 0   # insertion point, in characters, within s_query
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
var s_total_exact: bool = true  # false once the daemon stopped counting matches
var s_stream_id: number = 0     # request whose partial batches are on screen
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
    OnStart: OnDaemonStart,
    OnReady: OnDaemonReady,
  })
enddef

# ─────────────────── Waiting for the handshake ───────────────────
#
# EnsureBackend() only *starts* the daemon: the ping is on the wire and the
# pong has not come back, so simplefinder#core#HasCap() answers false for
# everything.  A request built in that window has to ask for the lowest common
# denominator — which meant the first grep of a session, of a restart, and of
# every crash-recovery went out with stream:false and came back in one lump.
# That is exactly the search most likely to be slow (nothing is cached yet),
# and :SimpleFinderGrep, GrepWord and GrepVisual are one-shot, so nothing ever
# re-sent them: the help promised streaming that the first search never did.
#
# Requests raised before the pong therefore wait for it and are re-dispatched
# from the panel's live state once capabilities are known.  The wait is
# bounded: a daemon that never answers still gets its request, un-negotiated
# and degraded exactly as before, rather than leaving the panel on `searching…`
# for good.
const NEGOTIATE_BUDGET_MS: number = 2000

var s_negotiated: bool = false      # capabilities known, or given up on
var s_negotiate_timer: number = 0
var s_deferred: bool = false        # a search is waiting for the handshake

def OnDaemonStart()
  # A restart renegotiates: the new process may be a different build.
  s_negotiated = false
  if s_negotiate_timer > 0
    timer_stop(s_negotiate_timer)
  endif
  s_negotiate_timer = timer_start(NEGOTIATE_BUDGET_MS, (_) => {
    s_negotiate_timer = 0
    FinishNegotiation()
  })
enddef

def OnDaemonReady(protocol: number, caps: dict<any>)
  FinishNegotiation()
enddef

def FinishNegotiation()
  if s_negotiate_timer > 0
    timer_stop(s_negotiate_timer)
    s_negotiate_timer = 0
  endif
  s_negotiated = true
  if !s_deferred
    return
  endif
  s_deferred = false
  # The panel may have been closed, or moved to another source, while the ping
  # was in flight.  DispatchSearch() reads the live panel state, so the first
  # thing worth checking is that there is still a panel to fill.
  if s_panel_winid == 0 || empty(getwininfo(s_panel_winid))
    s_loading = false
    return
  endif
  # And the second is that there is still a backend.  Re-dispatching goes
  # through EnsureBackend(), which *starts* the daemon: a request still held
  # when the process went away — :SimpleFinderStop, or a crash the supervisor
  # decided not to restart — would otherwise spawn a new one up to two seconds
  # later, silently undoing the stop.
  if !simplefinder#core#IsRunning()
    s_loading = false
    if s_error ==# ''
      s_error = 'backend stopped before the handshake completed'
    endif
    PanelRender()
    return
  endif
  DispatchSearch()
enddef

# :SimpleFinderStop is an instruction, not a pause: drop anything held for a
# handshake that is never going to arrive, rather than leave the panel on
# `searching…` until the budget runs out.
def CancelNegotiation()
  if s_negotiate_timer > 0
    timer_stop(s_negotiate_timer)
    s_negotiate_timer = 0
  endif
  if !s_deferred
    return
  endif
  s_deferred = false
  s_loading = false
  s_error = 'backend stopped before the handshake completed'
  PanelRender()
enddef

# True when the caller must hold this request back; the flush above re-runs it.
def AwaitNegotiation(): bool
  if s_negotiated
    return false
  endif
  s_deferred = true
  s_loading = true
  s_error = ''
  PanelRender()
  return true
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
  CancelNegotiation()
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

# =============================================================
# Configuration validation
#
# A mistyped option is the one failure with no symptom at all: every reader
# goes through get(g:, ...), so the misspelled name is simply never read and
# the line the user did write does nothing, for ever.  Nothing in the plugin
# was in a position to notice, because noticing means knowing the whole set of
# names — which is what the table below is.
# =============================================================

# Every documented option, declared once.  A table beats a wall of ifs for the
# reason that matters here: an option added to plugin/simplefinder.vim and not
# added below is reported as an *unknown* g:simplefinder_ name, so forgetting
# to describe an option fails loudly instead of quietly.
#
#   type      one of v:t_number / v:t_string / v:t_list / v:t_dict
#   flag      a number read as a truth value; v:true/v:false are fine too
#   allowed   the permitted strings
#   min       the smallest value the plugin actually honours
#   min_note  what the plugin does with a smaller one.  Its presence is what
#             makes an out-of-range value a WARN rather than an ERROR: the
#             behaviour is still defined, just not the one that was asked for.
#   items     'string' when a list may hold only non-empty strings
#   no_bang   list entries must not start with '!' — see ReadPathGlobList()
const CONFIG_SPEC: list<dict<any>> = [
  {name: 'debug', type: v:t_number, flag: true},
  {name: 'daemon_path', type: v:t_string},
  {name: 'max_results', type: v:t_number, min: 1},
  {name: 'threads', type: v:t_number, min: 0,
   min_note: 'the daemon runs one worker per core'},
  {name: 'grep_cache', type: v:t_number, flag: true},
  {name: 'debounce_ms', type: v:t_number, min: 0},
  {name: 'panel_width', type: v:t_number, min: 24,
   min_note: 'the panel opens at 24 columns'},
  {name: 'position', type: v:t_string, allowed: ['left', 'right']},
  {name: 'close_on_select', type: v:t_number, flag: true},
  {name: 'preview', type: v:t_number, flag: true},
  {name: 'preview_syntax', type: v:t_number, flag: true},
  {name: 'preview_width', type: v:t_number, min: 0},
  {name: 'preview_max_bytes', type: v:t_number, min: 0},
  {name: 'preview_cache', type: v:t_number, min: 1,
   min_note: 'one previewed file is always kept'},
  {name: 'hidden', type: v:t_number, flag: true},
  {name: 'no_ignore', type: v:t_number, flag: true},
  {name: 'regex', type: v:t_number, flag: true},
  {name: 'ignore_case', type: v:t_number, flag: true},
  {name: 'smart_case', type: v:t_number, flag: true},
  {name: 'recent_files_max', type: v:t_number, min: 1},
  {name: 'history_max', type: v:t_number, min: 0},
  {name: 'lines_max', type: v:t_number, min: 1},
  {name: 'root', type: v:t_string},
  {name: 'root_markers', type: v:t_list, items: 'string'},
  {name: 'include_globs', type: v:t_list, items: 'string', no_bang: true},
  {name: 'exclude_globs', type: v:t_list, items: 'string', no_bang: true},
  {name: 'symbol_keywords', type: v:t_dict},
  {name: 'symbol_all_languages', type: v:t_number, flag: true},
]

def TypeName(want: number): string
  if want == v:t_number
    return 'a number'
  elseif want == v:t_string
    return 'a string'
  elseif want == v:t_list
    return 'a list'
  endif
  return 'a dictionary'
enddef

# A value short enough to name in a diagnostic without swamping it.
def Brief(value: any): string
  var text = type(value) == v:t_string ? value : string(value)
  return strchars(text) > 40 ? strcharpart(text, 0, 40) .. '…' : text
enddef

def CheckList(spec: dict<any>, name: string, value: list<any>): list<string>
  if get(spec, 'items', '') !=# 'string'
    return []
  endif
  for entry in value
    if type(entry) != v:t_string || entry ==# ''
      return [printf('[ERROR] %s contains %s; every entry must be a non-empty string',
        name, Brief(entry))]
    endif
    # ReadPathGlobList() throws on a leading ! rather than guess which way the
    # user meant to invert the filter, so the search fails before it starts.
    if get(spec, 'no_bang', false) && entry[0] ==# '!'
      return [printf('[ERROR] %s contains %s; an exclusion belongs in '
        .. 'g:simplefinder_exclude_globs, not behind a leading !', name, Brief(entry))]
    endif
  endfor
  return []
enddef

def CheckOption(spec: dict<any>, value: any): list<string>
  var name = 'g:simplefinder_' .. spec.name
  var want: number = spec.type
  # A flag is read with `!= 0`, so v:true and v:false serve as well as 1 and 0.
  var is_bool = type(value) == v:t_bool && get(spec, 'flag', false)
  if type(value) != want && !is_bool
    # No claim about what happens next, because it differs per option: some
    # readers fall back to the default, while g:simplefinder_panel_width goes
    # through max() and aborts the panel with E1030.  The fact is enough.
    return [printf('[ERROR] %s = %s is not %s', name, Brief(value), TypeName(want))]
  endif
  if is_bool
    return []
  endif

  var problems: list<string> = []
  if want == v:t_number
    if has_key(spec, 'min') && value < spec.min
      add(problems, has_key(spec, 'min_note')
        ? printf('[WARN] %s = %d is below the minimum %d; %s',
            name, value, spec.min, spec.min_note)
        : printf('[ERROR] %s = %d is below the minimum %d', name, value, spec.min))
    endif
    if get(spec, 'flag', false) && value != 0 && value != 1
      add(problems, printf('[WARN] %s = %d is an on/off flag; anything but 0 means on',
        name, value))
    endif
  elseif want == v:t_string && has_key(spec, 'allowed')
    if index(spec.allowed, value) < 0
      add(problems, printf('[ERROR] %s = %s is not one of %s',
        name, Brief(value), join(spec.allowed, '/')))
    endif
  elseif want == v:t_list
    extend(problems, CheckList(spec, name, value))
  endif
  return problems
enddef

# Facts about the configuration that no single option can express on its own.
def CrossCheck(): list<string>
  var problems: list<string> = []

  var daemon_path = get(g:, 'simplefinder_daemon_path', '')
  if type(daemon_path) == v:t_string && daemon_path !=# '' && !executable(daemon_path)
    add(problems, printf('[ERROR] g:simplefinder_daemon_path = %s is not executable — '
      .. 'the usual lookup (runtimepath lib/, a target/ build, then $PATH) is used instead',
      Brief(daemon_path)))
  endif

  var root = get(g:, 'simplefinder_root', '')
  if type(root) == v:t_string && root !=# '' && !isdirectory(expand(root))
    add(problems, printf('[ERROR] g:simplefinder_root = %s is not a directory — '
      .. 'the root is detected from the markers instead', Brief(root)))
  endif

  # Both are legal and one simply wins; saying which one saves the user the
  # experiment of grepping for a capital letter and not understanding why.
  if get(g:, 'simplefinder_ignore_case', 0) != 0
      && get(g:, 'simplefinder_smart_case', 1) != 0
    add(problems, '[WARN] g:simplefinder_ignore_case overrides '
      .. 'g:simplefinder_smart_case; set only one')
  endif

  # The preview popup is never opened narrower than 30 columns, so a width
  # between 1 and 29 does something other than what it says.
  var preview_width = get(g:, 'simplefinder_preview_width', 0)
  if type(preview_width) == v:t_number && preview_width > 0 && preview_width < 30
    add(problems, printf('[WARN] g:simplefinder_preview_width = %d is below the '
      .. 'minimum 30; the preview opens at 30 columns', preview_width))
  endif

  var keywords = get(g:, 'simplefinder_symbol_keywords', {})
  if type(keywords) == v:t_dict
    for [filetype, list] in items(keywords)
      if type(list) != v:t_list
        add(problems, printf('[ERROR] g:simplefinder_symbol_keywords[%s] is not a list — '
          .. "the built-in keywords for that filetype are used instead", filetype))
        continue
      endif
      for keyword in list
        if type(keyword) != v:t_string || keyword ==# ''
          add(problems, printf('[ERROR] g:simplefinder_symbol_keywords[%s] contains %s; '
            .. 'every keyword must be a non-empty string', filetype, Brief(keyword)))
          break
        endif
      endfor
    endfor
  endif
  return problems
enddef

# Everything wrong with the configuration as it stands, as `[LEVEL] fact —
# remedy` lines.  An empty list means there is nothing to say.
#
# Nothing here throws and nothing here changes anything: a bad option is
# reported and then left alone by the code that reads it, because a finder that
# refuses to open is a worse answer to a typo than one that opens on defaults.
export def ValidateConfig(): list<string>
  var problems: list<string> = []
  var known: dict<bool> = {}
  for spec in CONFIG_SPEC
    var key = 'simplefinder_' .. spec.name
    known[key] = true
    if has_key(g:, key)
      extend(problems, CheckOption(spec, g:[key]))
    endif
  endfor
  extend(problems, CrossCheck())

  # Only names this plugin owns are considered: g:loaded_simplefinder is the
  # load guard and a bare g:simplefinder belongs to whoever set it, so neither
  # is ours to complain about.
  for key in sort(keys(g:))
    if key =~# '^simplefinder_' && !has_key(known, key)
      add(problems, printf('[ERROR] g:%s is not a SimpleFinder option — check the '
        .. 'spelling against :help simplefinder-config', key))
    endif
  endfor
  return problems
enddef

# Validation runs once, on the first panel of the session, and echoes only the
# ERROR lines: a warning is a value the plugin still honours, and belongs in
# :SimpleFinderHealth where the user went looking for it, rather than in front
# of a search they just asked for.
var s_config_checked: bool = false

def CheckConfigOnce()
  if s_config_checked
    return
  endif
  s_config_checked = true
  for line in ValidateConfig()
    if line =~# '^\[ERROR\]'
      echohl WarningMsg | echom '[SimpleFinder] ' .. line | echohl NONE
    endif
  endfor
enddef

# =============================================================
# Health report
# =============================================================

# The plugin's own directory, resolved once from this very script rather than
# from &runtimepath, which may hold several checkouts.  Everything about
# versions is relative to it: Cargo.toml for the version the Vim files shipped
# with, src/ for whether the binary predates them.
const PLUGIN_ROOT: string = expand('<sfile>:p:h:h')

def PluginVersion(): string
  var manifest = PLUGIN_ROOT .. '/Cargo.toml'
  if !filereadable(manifest)
    return ''
  endif
  # [package] comes first, so the first bare `version =` is the crate's; the
  # 20-line budget keeps `rust-version` and the dependency table out of it.
  for line in readfile(manifest, '', 20)
    var version = matchstr(line, '^version\s*=\s*"\zs[^"]\+\ze"')
    if version !=# ''
      return version
    endif
  endfor
  return ''
enddef

# The daemon's own --version, probed with job_start().
#
# Never system(): this report is what you run *because* something is wedged,
# and a synchronous probe of a wedged binary hangs the very command you are
# using to diagnose it.  The answer is cached per binary — path *and* mtime, so
# a rebuild is probed again — and the report redraws itself when the answer
# lands, so the first one says `probing…` and then fills itself in.
var s_probe: dict<any> = {key: '', state: 'idle', version: ''}

def ProbeVersion(exe: string)
  if exe ==# '' || !has('job')
    return
  endif
  var key = exe .. '@' .. getftime(exe)
  if s_probe.key ==# key && s_probe.state !=# 'idle'
    return
  endif
  s_probe = {key: key, state: 'running', version: ''}
  var output: list<string> = []
  var job = job_start([exe, '--version'], {
    out_cb: (_, msg: string) => {
      add(output, msg)
    },
    exit_cb: (_, status: number) => {
      # A rebuild, or a different binary, may have started a newer probe while
      # this one was still running: the newest key owns the answer.
      if s_probe.key !=# key
        return
      endif
      s_probe.version = matchstr(join(output, ' '), '\d\+\.\d\+\.\d\+')
      s_probe.state = status == 0 && s_probe.version !=# '' ? 'done' : 'failed'
      RefreshHealthBuffer()
    },
    err_io: 'null',
  })
  # job_start() hands back a job even when the exec failed, and then no
  # exit callback ever arrives; without this the report says `probing…` for
  # the rest of the session.
  if job_status(job) ==# 'fail'
    s_probe.state = 'failed'
  endif
enddef

def BinaryLines(): list<string>
  var lines: list<string> = []
  var exe = simplefinder#core#ExePath()
  if exe ==# ''
    exe = simplefinder#core#FindExe()
  endif
  if exe ==# ''
    add(lines, '[ERROR] binary: not found — run ./install.sh in ' .. PLUGIN_ROOT)
    return lines
  endif
  add(lines, printf('[OK] binary: %s', exe))

  # The classic upgrade failure: a plugin manager pulls new Vim files and new
  # Rust sources, nothing rebuilds lib/, and everything then looks healthy
  # while a capability the help documents is quietly missing.
  var built = getftime(exe)
  var newest = 0
  for source in glob(PLUGIN_ROOT .. '/src/**/*.rs', true, true)
    newest = max([newest, getftime(source)])
  endfor
  if built > 0 && newest > built
    add(lines, '[WARN] binary is older than src/ — run ./install.sh, '
      .. 'then :SimpleFinderRestart')
  endif

  ProbeVersion(exe)
  var plugin_version = PluginVersion()
  if s_probe.state ==# 'running'
    add(lines, '[INFO] version: probing…')
  elseif s_probe.state ==# 'idle'
    add(lines, '[INFO] version: not probed — this Vim has no +job')
  elseif s_probe.state ==# 'failed'
    add(lines, '[ERROR] version: the binary did not answer --version — '
      .. 'run ./install.sh, then :SimpleFinderRestart')
  elseif plugin_version !=# '' && s_probe.version !=# plugin_version
    add(lines, printf('[ERROR] version: daemon %s, plugin %s — an upgrade left the '
      .. 'old binary behind; run ./install.sh, then :SimpleFinderRestart',
      s_probe.version, plugin_version))
  else
    add(lines, printf('[OK] version: %s', s_probe.version))
  endif
  return lines
enddef

# Nothing here is optional: the daemon is a job, its replies arrive on a
# channel, every debounce is a timer, the panel highlights matches with text
# properties and the preview is a popup.  None of those calls is guarded, so a
# Vim missing any of them does not degrade — it throws.
const REQUIRED_FEATURES: list<string> = ['job', 'channel', 'timers', 'textprop', 'popupwin']

def EnvironmentLines(): list<string>
  var lines: list<string> = []
  add(lines, printf('[%s] vim: %d.%d (needs 9.0 or later, with :vim9script)',
    has('vim9script') ? 'OK' : 'ERROR', v:version / 100, v:version % 100))
  var missing = filter(copy(REQUIRED_FEATURES), (_, f) => !has(f))
  if empty(missing)
    add(lines, printf('[OK] features: %s',
      join(mapnew(REQUIRED_FEATURES, (_, f) => '+' .. f), ', ')))
  else
    add(lines, printf('[ERROR] features: missing %s — rebuild Vim with them',
      join(mapnew(missing, (_, f) => '+' .. f), ', ')))
  endif
  add(lines, printf('[%s] encoding: %s',
    &encoding ==# 'utf-8' ? 'OK' : 'WARN', &encoding))
  return lines
enddef

def RuntimeLines(): list<string>
  var lines: list<string> = []
  var core = simplefinder#core#Health()
  if !core.running && core.starts == 0
    # The daemon starts with the first search, so before then `not running` is
    # the expected state and not a fault.  Reporting it as an error opened the
    # one command a user runs when something is wrong with a red herring, and
    # sent every bug report that quoted it down the same blind alley.
    add(lines, '[INFO] daemon: not started yet — it starts with the first search')
    return lines
  endif
  extend(lines, simplefinder#core#HealthLines())
  if simplefinder#core#Ready() && empty(simplefinder#core#Caps())
    add(lines, '[WARN] daemon predates the capability handshake — '
      .. 'run ./install.sh, then :SimpleFinderRestart')
  endif
  return lines
enddef

def ContextLines(): list<string>
  var lines: list<string> = []
  add(lines, printf('[INFO] project root: %s',
    s_project_root ==# '' ? '(resolved on the first search)' : s_project_root))
  try
    var includes = ReadPathGlobList('simplefinder_include_globs')
    var excludes = ReadPathGlobList('simplefinder_exclude_globs')
    add(lines, printf('[INFO] path globs: %d include, %d exclude',
      len(includes), len(excludes)))
  catch
    # A glob list this file refuses to read is not cosmetic: the panel opens
    # on the error instead of on results.
    add(lines, '[ERROR] path globs: ' .. v:exception)
  endtry
  add(lines, printf('[INFO] preview: %s',
    get(g:, 'simplefinder_preview', 1) != 0
      ? 'on by default' : 'off (g:simplefinder_preview = 0)'))
  return lines
enddef

# Fixed sections, always in this order and always present, so two reports from
# two machines can be read side by side and a missing fact reads as a missing
# fact rather than as a shorter report.
def AddSection(lines: list<string>, title: string, body: list<string>)
  add(lines, '')
  add(lines, title)
  extend(lines, body)
enddef

def HealthReport(): list<string>
  SetupCore()
  var lines = ['SimpleFinder health', repeat('─', 60)]
  AddSection(lines, 'ENVIRONMENT', EnvironmentLines())
  AddSection(lines, 'BINARY', BinaryLines())
  var config = ValidateConfig()
  AddSection(lines, 'CONFIG', empty(config)
    ? ['[OK] every option holds a value this plugin understands']
    : config)
  AddSection(lines, 'RUNTIME', RuntimeLines())
  AddSection(lines, 'CONTEXT', ContextLines())
  return lines
enddef

const HEALTH_BUFNAME = 'SimpleFinderHealth'
var s_health_bufnr: number = -1

# Redraw the report in place, without stealing focus, when the version probe
# lands after the buffer was already on screen.
def RefreshHealthBuffer()
  if s_health_bufnr <= 0 || !bufloaded(s_health_bufnr)
      || empty(win_findbuf(s_health_bufnr))
    return
  endif
  var report = HealthReport()
  setbufvar(s_health_bufnr, '&modifiable', 1)
  deletebufline(s_health_bufnr, 1, '$')
  setbufline(s_health_bufnr, 1, report)
  setbufvar(s_health_bufnr, '&modifiable', 0)
  setbufvar(s_health_bufnr, '&modified', 0)
enddef

# The report is a scratch buffer rather than a wall of :echom, because it is
# read, scrolled and pasted into bug reports — none of which the message area
# supports, and the last of which is the whole point of the command.
export def Health()
  var report = HealthReport()
  var windows = s_health_bufnr > 0 && bufexists(s_health_bufnr)
    ? win_findbuf(s_health_bufnr) : []
  if !empty(windows)
    win_gotoid(windows[0])
  elseif s_health_bufnr > 0 && bufexists(s_health_bufnr)
    execute 'silent keepalt botright sbuffer ' .. s_health_bufnr
  else
    execute 'silent keepalt botright split ' .. fnameescape(HEALTH_BUFNAME)
    s_health_bufnr = bufnr('%')
  endif
  setlocal buftype=nofile bufhidden=hide noswapfile nobuflisted nowrap
  setlocal modifiable
  silent deletebufline('%', 1, '$')
  setline(1, report)
  setlocal nomodifiable nomodified
  execute 'resize ' .. min([len(report) + 1, max([10, &lines / 2])])
  normal! gg
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
  var id = get(ev, 'id', 0)
  # A streaming daemon repaints the same request several times, each batch a
  # refined snapshot rather than an append.  The first batch of a request is a
  # new result set and belongs at the top; a later one must not yank the
  # viewport, so the row under the cursor is followed by its stable identity —
  # a match found late can sort in above it and shift every index below.
  var anchor = ''
  var anchor_row = 0
  if id != 0 && id == s_stream_id && s_cursor_idx < len(s_items)
    anchor = ItemIdentity(s_items[s_cursor_idx])
    # Following the identity restores the *selection*; the viewport is a second,
    # independent thing.  Zeroing the scroll offset and letting PanelRender pull
    # it back just far enough to expose the cursor scrolls the whole panel to the
    # top on every batch, so keep the anchored row where the eye left it instead.
    anchor_row = s_cursor_idx - s_scroll_off
  endif

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
  # A daemon that stopped counting at its scan ceiling says so; one too old to
  # know about the field reports total == len(items) anyway, so defaulting to
  # true cannot turn a lower bound into a claimed exact count.
  s_total_exact = get(ev, 'total_exact', true)
  s_elapsed_ms = get(ev, 'elapsed_ms', 0)
  s_error = ''

  # `done` has always been on the wire; until streaming landed it was always
  # true, so a daemon that does not stream still takes exactly this path once.
  var done = get(ev, 'done', true)
  s_loading = !done
  s_current_id = done ? 0 : id
  s_stream_id = done ? 0 : id

  s_cursor_idx = 0
  s_scroll_off = 0
  if anchor !=# ''
    AssignItemIdentities(s_items)
    var found = indexof(s_items, (_, item) => ItemIdentity(item) ==# anchor)
    if found >= 0
      s_cursor_idx = found
      # PanelRender clamps this against the item count and the viewport height.
      s_scroll_off = max([0, found - anchor_row])
    endif
  endif
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
  # Whatever the panel was searching for is now history, even when the user
  # went straight from one source to another without closing it.
  RecordHistory()

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
  SetQuery(initial_query)
  s_history_idx = -1
  s_items = []
  s_cursor_idx = 0
  s_scroll_off = 0
  s_total = 0
  s_current_id = 0
  s_loading = false
  s_error = ''
  s_elapsed_ms = 0
  s_capped = false
  s_total_exact = true
  s_stream_id = 0
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
  s_preview_scroll = 0
  s_project_root = FindProjectRoot()

  EnsurePanel()
  SetupSyntax()
  PanelRender()
  # After the render, not before it: a message echoed first is painted over by
  # the panel and the user never sees the one thing that explains why their
  # setting is not taking effect.
  CheckConfigOnce()
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
  RecordHistory()
  PreviewClose()
  PreviewCacheClear()
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
  # win_id2win() is tabpage-local: it returns 0 for a live panel that simply
  # lives in another tab.  Guarding on it meant results arriving while you were
  # elsewhere were stored and never drawn, so coming back showed a stale
  # `searching…` until the next keypress.  getwininfo() and setbufline() are
  # both tabpage-agnostic, so there is nothing to skip.
  var panel_info = s_panel_winid == 0 ? [] : getwininfo(s_panel_winid)
  if empty(panel_info) || s_panel_bufnr < 0
    return
  endif
  AssignItemIdentities(s_items)

  s_eff_width = panel_info[0].width
  s_eff_height = panel_info[0].height
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
  var title = s_mode ==# 'list' ? s_list_title : get(mode_names, s_mode, s_mode)
  var count_str = ''
  if s_loading
    # A streamed search paints partial results while the walk is still going,
    # so say how much is on screen as well as that more is coming.
    count_str = empty(s_items)
      ? 'searching…'
      : printf('%d results · searching…', len(s_items))
  elseif s_error !=# ''
    count_str = 'error'
  elseif s_capped && s_total > len(s_items)
    # An honest cap: how many were kept out of how many exist. The trailing +
    # marks a total the daemon stopped counting at its scan ceiling.
    count_str = printf('%d/%d%s results', len(s_items), s_total,
      s_total_exact ? '' : '+')
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
  # The block glyph is the query cursor, so it is drawn where the next
  # character will be inserted rather than always at the end.
  s_query_cursor = max([0, min([s_query_cursor, strchars(s_query)])])
  add(lines, TruncDisplay(' > ' .. strcharpart(s_query, 0, s_query_cursor)
    .. "\u2581" .. strcharpart(s_query, s_query_cursor) .. flags, width))

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
  var help = " \u23ce open  \u21e5 mark  ^f edit  ^q qf  ^l loc  ^e preview  esc"
  if s_error !=# '' && !empty(s_items)
    help = ' ! ' .. s_error
  elseif s_mode ==# 'grep' || s_mode ==# 'igrep'
    help = ' ^f edit  ^r regex  ^a case  ^o hidden  ^g ignores  ^q qf  ^l loc'
  elseif s_mode ==# 'buffers'
    help = " \u23ce open  \u21e5 mark  ^f edit  ^d bdelete  ^q qf  ^l loc  esc"
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
  # win_execute() reaches a window in any tabpage, so this must not use the
  # tabpage-local win_id2win() either — the cursor row has to be right when
  # the user comes back to the tab, not one repaint later.
  if s_panel_winid == 0 || empty(getwininfo(s_panel_winid)) || s_panel_bufnr < 0
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
  elseif s_mode ==# 'list'
    # A picker source renders itself: the row is whatever the source put in
    # `display`, which is also the field the fuzzy filter matches, so the
    # highlight offsets below line up with no per-source arithmetic.
    line = marker .. get(item, 'display', '')
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
  # A preview scrolled with <PageDown> is scrolled relative to the match being
  # looked at, so selecting another result starts it over.
  s_preview_scroll = 0

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

var s_preview_scroll: number = 0   # extra lines scrolled past the match line
var s_preview_syntax: string = ''  # what the popup window is currently set to

# Cached whole-file reads, newest first: {key: '<path>:<ftime>:<size>', lines}.
#
# The preview used to call readfile(path, '', start + height - 1) on every
# cursor move, which reads the file from byte 0 down to the line it wants: a
# result 30,000 lines into a file re-parsed 30,000 lines per <C-j>, and moving
# between two results in the same file paid for it twice.  Reading the file
# once and slicing it is the same work for a single visit and free thereafter;
# the size guard below bounds what that can cost.
var s_preview_cache: list<dict<any>> = []

def PreviewCacheClear()
  s_preview_cache = []
enddef

def CachedFileLines(path: string): list<string>
  var key = printf('%s:%d:%d', path, getftime(path), getfsize(path))
  var hit = indexof(s_preview_cache, (_, e) => e.key ==# key)
  if hit >= 0
    if hit > 0
      # Most recently used first, so the eviction below drops the coldest.
      insert(s_preview_cache, remove(s_preview_cache, hit), 0)
    endif
    return s_preview_cache[0].lines
  endif
  var lines: list<string> = []
  try
    lines = readfile(path)
  catch
    return []
  endtry
  insert(s_preview_cache, {key: key, lines: lines}, 0)
  var mx = max([1, get(g:, 'simplefinder_preview_cache', 4)])
  if len(s_preview_cache) > mx
    s_preview_cache = s_preview_cache[: mx - 1]
  endif
  return lines
enddef

# The loaded buffer showing `path`, if there is one.
#
# bufnr() takes a *pattern*, so a path holding regex punctuation would match
# the wrong buffer or none at all; comparing full names is both cheaper to
# reason about and correct.
def LoadedBufferFor(path: string): number
  if path ==# ''
    return 0
  endif
  var full = fnamemodify(path, ':p')
  for info in getbufinfo({bufloaded: 1})
    if info.name !=# '' && fnamemodify(info.name, ':p') ==# full
      return info.bufnr
    endif
  endfor
  return 0
enddef

# What the preview should show, and where it should come from.
#
# A buffer with unsaved edits is the authority on its own content: previewing
# the file on disk showed text that no longer matched the result — in `lines`
# mode the item text comes from getline(), so after five inserted lines the
# highlighted preview line did not contain the match at all.
def PreviewSlice(path: string, buf: number, start: number, count: number): list<string>
  if buf > 0 && bufloaded(buf)
    return getbufline(buf, start, start + count - 1)
  endif
  var all = CachedFileLines(path)
  if len(all) < start
    return []
  endif
  return all[start - 1 : start + count - 2]
enddef

def PreviewLineCount(path: string, buf: number): number
  if buf > 0 && bufloaded(buf)
    return getbufinfo(buf)[0].linecount
  endif
  return len(CachedFileLines(path))
enddef

# Extension -> filetype for files that are not open in a buffer.  Vim's own
# filetype detection needs a buffer to run against, and creating one per
# preview would fire autocommands for a file the user only pointed at.
var s_preview_filetypes: dict<string> = {
  rs: 'rust', py: 'python', js: 'javascript', jsx: 'javascriptreact',
  ts: 'typescript', tsx: 'typescriptreact', go: 'go', c: 'c', h: 'c',
  cc: 'cpp', cpp: 'cpp', cxx: 'cpp', hpp: 'cpp', hh: 'cpp', java: 'java',
  rb: 'ruby', lua: 'lua', vim: 'vim', sh: 'sh', bash: 'bash', zsh: 'zsh',
  hs: 'haskell', jl: 'julia', php: 'php', cs: 'cs', kt: 'kotlin',
  swift: 'swift', scala: 'scala', pl: 'perl', r: 'r', sql: 'sql',
  md: 'markdown', markdown: 'markdown', rst: 'rst', tex: 'tex',
  json: 'json', yaml: 'yaml', yml: 'yaml', toml: 'toml', ini: 'dosini',
  conf: 'conf', xml: 'xml', html: 'html', css: 'css', scss: 'scss',
  txt: '', log: '',
}

def PreviewFiletype(path: string, buf: number): string
  if get(g:, 'simplefinder_preview_syntax', 1) == 0
    return ''
  endif
  if buf > 0 && bufloaded(buf)
    return getbufvar(buf, '&filetype')
  endif
  var name = fnamemodify(path, ':t')
  if name ==# 'Makefile' || name ==# 'makefile'
    return 'make'
  endif
  return get(s_preview_filetypes, tolower(fnamemodify(path, ':e')), '')
enddef

def PreviewClose()
  if s_preview_winid > 0
    try
      popup_close(s_preview_winid)
    catch
    endtry
    s_preview_winid = 0
    s_preview_syntax = ''
  endif
enddef

# Scroll the preview without moving the selection.  The offset is in lines and
# is reset whenever the selected result changes, so scrolling is always
# relative to the match you are looking at.
def PreviewScroll(delta: number)
  if !s_preview_on || s_preview_winid <= 0
    return
  endif
  s_preview_scroll += delta
  PreviewUpdate()
enddef

def PreviewUpdate()
  var panel_info = s_panel_winid == 0 ? [] : getwininfo(s_panel_winid)
  if !s_preview_on || empty(panel_info)
    PreviewClose()
    return
  endif
  # PanelRender() is tabpage-agnostic and repaints a panel wherever it lives,
  # but a popup is not: it is created in the current tabpage, and its geometry
  # below comes from the panel window.  From another tab win_id2win() answers
  # 0 and win_screenpos(0) means "the current window", so drawing anyway put a
  # preview over whatever the user was editing in a tab with no panel in it.
  # The preview is redrawn when the user comes back to the panel.
  if panel_info[0].tabnr != tabpagenr()
    PreviewClose()
    return
  endif
  if empty(s_items) || s_cursor_idx >= len(s_items)
    PreviewClose()
    return
  endif
  var item = s_items[s_cursor_idx]
  # No expand() here: it is a wildcard, environment-variable and %/#-special
  # expander pointed at a file name, and a name is not an expression.
  # fnamemodify(':p') resolves '~' and relative paths, which is all that is
  # wanted.
  var raw_path = ResolvePath(item)
  var path = raw_path ==# '' ? '' : fnamemodify(raw_path, ':p')
  var buf = get(item, 'bufnr', 0)
  if buf <= 0 || !bufloaded(buf)
    buf = LoadedBufferFor(path)
  endif
  if buf <= 0 && (path ==# '' || !filereadable(path))
    PreviewClose()
    return
  endif

  # Fill the space beside the panel; skip when too narrow to be useful
  var pcol = panel_info[0].wincol
  var width = 0
  var col = 2
  if get(g:, 'simplefinder_position', 'right') !=# 'left'
    width = pcol - 4
    col = 2
  else
    col = pcol + s_eff_width + 3
    width = &columns - col - 1
  endif
  var wanted = get(g:, 'simplefinder_preview_width', 0)
  if wanted > 0
    width = min([width, max([30, wanted])])
  endif
  if width < 30
    PreviewClose()
    return
  endif
  var height = max([5, s_eff_height - 2])

  var lnum = get(item, 'lnum', 0)
  var lines: list<string> = []
  var hl_line = 0
  var syntax = ''
  # An unsaved buffer is read from memory, so its size on disk says nothing
  # about the cost of previewing it.
  var fsize = buf > 0 && bufloaded(buf) ? 0 : getfsize(path)
  var max_bytes = get(g:, 'simplefinder_preview_max_bytes', 2097152)
  if fsize < 0 || (max_bytes > 0 && fsize > max_bytes)
    lines = ['── file too large to preview ──']
    s_preview_scroll = 0
  else
    var total = PreviewLineCount(path, buf)
    var start = 1
    if lnum > 0
      start = max([1, lnum - height / 2])
    endif
    # Clamp the scroll offset against the file rather than letting it run off
    # either end: <PageDown> at the bottom must simply stop.
    var lowest = 1 - start
    var highest = max([lowest, total - height + 1 - start])
    s_preview_scroll = max([lowest, min([s_preview_scroll, highest])])
    start += s_preview_scroll
    lines = PreviewSlice(path, buf, start, height)
    if empty(lines)
      lines = ['── empty file ──']
    else
      syntax = PreviewFiletype(path, buf)
      if lnum > 0 && lnum >= start && lnum < start + height
        hl_line = lnum - start + 1
      endif
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
  # Syntax is per window and survives popup_settext, so it is only worth
  # setting when it actually changes — highlighting a 40-line popup is cheap,
  # re-sourcing a syntax file on every <C-j> is not.
  if syntax !=# s_preview_syntax
    s_preview_syntax = syntax
    try
      win_execute(s_preview_winid, 'setlocal syntax=' .. (syntax ==# '' ? 'OFF' : syntax))
    catch
    endtry
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
  nnoremap <silent><buffer> <C-f> <ScriptCmd>PanelHandleKey(0, '<lt>C-f>')<CR>
  nnoremap <silent><buffer> <C-y> <ScriptCmd>PanelHandleKey(0, '<lt>C-y>')<CR>
  nnoremap <silent><buffer> <Left> <ScriptCmd>PanelHandleKey(0, '<lt>Left>')<CR>
  nnoremap <silent><buffer> <Right> <ScriptCmd>PanelHandleKey(0, '<lt>Right>')<CR>
  nnoremap <silent><buffer> <Home> <ScriptCmd>PanelHandleKey(0, '<lt>Home>')<CR>
  nnoremap <silent><buffer> <End> <ScriptCmd>PanelHandleKey(0, '<lt>End>')<CR>
  nnoremap <silent><buffer> <C-Up> <ScriptCmd>PanelHandleKey(0, '<lt>C-Up>')<CR>
  nnoremap <silent><buffer> <C-Down> <ScriptCmd>PanelHandleKey(0, '<lt>C-Down>')<CR>
  nnoremap <silent><buffer> <PageUp> <ScriptCmd>PanelHandleKey(0, '<lt>PageUp>')<CR>
  nnoremap <silent><buffer> <PageDown> <ScriptCmd>PanelHandleKey(0, '<lt>PageDown>')<CR>

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
    '<C-f>': "\<C-f>",
    '<C-y>': "\<C-y>",
    '<Left>': "\<Left>",
    '<Right>': "\<Right>",
    '<Home>': "\<Home>",
    '<End>': "\<End>",
    '<C-Up>': "\<C-Up>",
    '<C-Down>': "\<C-Down>",
    '<PageUp>': "\<PageUp>",
    '<PageDown>': "\<PageDown>",
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
  if k ==# "\<PageDown>"
    PreviewScroll(max([1, s_eff_height / 2]))
    return true
  endif
  if k ==# "\<PageUp>"
    PreviewScroll(-max([1, s_eff_height / 2]))
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
        s_preview_scroll = 0
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
        s_preview_scroll = 0
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

  # Query cursor motion.  Nothing is searched again: the query has not changed,
  # only where the next character will land.
  if k ==# "\<Left>"
    MoveQueryCursor(-1)
    return true
  endif
  if k ==# "\<Right>"
    MoveQueryCursor(1)
    return true
  endif
  if k ==# "\<Home>"
    s_query_cursor = 0
    PanelRender()
    return true
  endif
  if k ==# "\<End>"
    s_query_cursor = strchars(s_query)
    PanelRender()
    return true
  endif

  # Query history, per source.
  if k ==# "\<C-Up>"
    RecallHistory(1)
    return true
  endif
  if k ==# "\<C-Down>"
    RecallHistory(-1)
    return true
  endif

  # Editing
  if k ==# "\<BS>" || k ==# "\<C-h>"
    if s_query_cursor > 0
      ReplaceQueryRange(s_query_cursor - 1, s_query_cursor, '')
    endif
    return true
  endif
  if k ==# "\<C-u>"
    ReplaceQueryRange(0, strchars(s_query), '')
    return true
  endif
  if k ==# "\<C-w>"
    # Delete the word before the cursor, leaving anything after it alone.
    var before = strcharpart(s_query, 0, s_query_cursor)
    var kept = substitute(before, '\S*\s*$', '', '')
    ReplaceQueryRange(strchars(kept), s_query_cursor, '')
    return true
  endif

  if k ==# "\<C-f>"
    EditQueryLine()
    return true
  endif
  if k ==# "\<C-y>"
    PasteRegister()
    return true
  endif

  # Printable text: one keystroke from the <Char-NN> mappings above, or a whole
  # string handed back by the command-line editor.
  if k !=# '' && char2nr(k) >= 32
    ReplaceQueryRange(s_query_cursor, s_query_cursor, k)
    return true
  endif

  # Consume all other keys
  return true
enddef

# ─────────────────── Query editing ───────────────────
#
# The query used to be append-only: every edit landed at the end, so a typo in
# the middle of a long pattern meant deleting everything after it.  It is now a
# real insertion point, kept in *characters* so a multi-byte query (which <C-f>
# and <C-y> can produce) cannot be cut through the middle of a character.

def MoveQueryCursor(delta: number)
  var moved = max([0, min([s_query_cursor + delta, strchars(s_query)])])
  if moved == s_query_cursor
    return
  endif
  s_query_cursor = moved
  PanelRender()
enddef

# Set the whole query at once (command-line edit, history recall, resume).
def SetQuery(text: string)
  s_query = text
  s_query_cursor = strchars(text)
enddef

# The single place the query text changes while the panel is open: replaces the
# character range [from, to) with `text`, leaves the cursor after what was
# inserted, and re-searches.  Editing always leaves history recall, so <C-Up>
# starts again from the query now on screen rather than from where recall was.
def ReplaceQueryRange(from: number, to: number, text: string)
  var total = strchars(s_query)
  var lo = max([0, min([from, total])])
  var hi = max([lo, min([to, total])])
  if lo == hi && text ==# ''
    return
  endif
  s_query = strcharpart(s_query, 0, lo) .. text .. strcharpart(s_query, hi)
  s_query_cursor = lo + strchars(text)
  s_history_idx = -1
  s_cursor_idx = 0
  s_scroll_off = 0
  DebouncedSearch()
  PanelRender()
enddef

# Splice a register into the query at the cursor.
#
# Registers are where paths, identifiers and error messages already are — the
# thing you want to search for is usually one yank away — and a register is
# also the shortest route to text no keyboard mapping can produce: the panel
# reads keystrokes with one mapping per printable ASCII character, so a yanked
# CJK identifier reaches the query this way when typing it cannot.
def PasteRegister()
  echo '"'
  var name: string
  try
    name = exists('*getcharstr') ? getcharstr() : nr2char(getchar())
  catch /^Vim:Interrupt$/
    return
  endtry
  redraw
  if name ==# '' || name ==# "\<Esc>" || name ==# "\<C-c>"
    return
  endif
  var text: string
  try
    text = getreg(name)
  catch
    # An unknown register name is a typo, not an error worth a panel line.
    return
  endtry
  if text ==# ''
    return
  endif
  # A linewise register ends in a newline and may hold several lines; a query
  # is one line, so join it the way the multi-line Visual selection does.
  text = substitute(text, '[\r\n]\+$', '', '')
  text = substitute(text, '[\r\n]\+', ' ', 'g')
  if text ==# ''
    return
  endif
  ReplaceQueryRange(s_query_cursor, s_query_cursor, text)
enddef

# ─────────────────── Query history ───────────────────
#
# Per source, because the queries are not interchangeable: a file path fragment
# is not a grep pattern, and cycling through the wrong kind is worse than
# having no history at all.  Kept in memory for the session only — writing a
# state file would need a documented location, a size policy and a story about
# concurrent Vim instances, none of which are needed to fix "I want the pattern
# I ran a minute ago".

var s_history: dict<list<string>> = {}
var s_history_idx: number = -1    # -1 = editing; 0.. = index into the list
var s_history_stash: string = ''  # the query recall started from

# grep and igrep are the same search with different entry points, so they share
# one list; everything else keeps its own.
def HistoryKey(mode: string): string
  return mode ==# 'igrep' ? 'grep' : mode
enddef

def RecordHistory()
  if s_mode ==# '' || s_query ==# ''
    return
  endif
  var key = HistoryKey(s_mode)
  var entries = get(s_history, key, [])
  filter(entries, (_, v) => v !=# s_query)
  insert(entries, s_query, 0)
  var mx = max([0, get(g:, 'simplefinder_history_max', 50)])
  if len(entries) > mx
    entries = mx == 0 ? [] : entries[: mx - 1]
  endif
  s_history[key] = entries
enddef

# delta > 0 walks towards older queries, < 0 back towards the one being edited.
def RecallHistory(delta: number)
  var entries = get(s_history, HistoryKey(s_mode), [])
  if empty(entries)
    return
  endif
  if s_history_idx < 0
    if delta < 0
      return
    endif
    s_history_stash = s_query
  endif
  var idx = s_history_idx + delta
  if idx >= len(entries)
    return
  endif
  if idx < 0
    idx = -1
    SetQuery(s_history_stash)
  else
    SetQuery(entries[idx])
  endif
  s_history_idx = idx
  s_cursor_idx = 0
  s_scroll_off = 0
  DebouncedSearch()
  PanelRender()
enddef

# Hand the query to Vim's command line for one edit.
#
# The panel reads keystrokes by mapping <Char-32> through <Char-126>, one
# mapping per character: that is the whole of printable ASCII and nothing else.
# A non-ASCII keystroke matches no mapping, lands in a nomodifiable nofile
# buffer in Normal mode and is dropped without a word -- so in a plugin whose
# own README is written in Chinese there was no way to grep a Chinese
# identifier from the panel at all.  input() borrows the real command line for
# one edit, which brings every input method with it, along with the two other
# things a one-mapping-per-character reader cannot offer: moving about inside
# the query, and pasting a register with CTRL-R.
def EditQueryLine()
  var edited: string
  try
    # The dict form of input() carries a cancelreturn, but Vim9's compiled
    # signature for input() in a 9.1 build only declares the string arguments,
    # so it is a type error here.  Without it <Esc> and an empty line are
    # indistinguishable, so treat both as "leave the query alone" -- the panel
    # already has CTRL-U for clearing it, and silently wiping a query someone
    # cancelled out of is the worse of the two failure modes.
    edited = input('> ', s_query)
  catch /^Vim:Interrupt$/
    return
  endtry
  redraw
  if edited ==# '' || edited ==# s_query
    return
  endif
  SetQuery(edited)
  s_history_idx = -1
  s_cursor_idx = 0
  s_scroll_off = 0
  DebouncedSearch()
  PanelRender()
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
  elseif s_mode ==# 'list'
    FilterList()
  endif
enddef

# =============================================================
# Search functions — daemon-based
# =============================================================

# Worker threads for the daemon's walk and its scoring.  0 (the default) means
# one per core; the daemon clamps anything absurd.
def RequestThreads(): number
  var value = get(g:, 'simplefinder_threads', 0)
  return type(value) == v:t_number && value > 0 ? value : 0
enddef

# Whether this grep may share the file finder's picture of the tree.
#
# Interactive grep sends a request per keystroke and each one re-walked the
# whole project — every .gitignore re-read, every directory stat-ed again —
# before a single file could be searched.  The daemon already keeps that list
# for the file finder, so grep can read it instead, and publish its own walk
# into it when it does have to walk.  The list is at most 30 seconds old, which
# is the trade: a file created mid-session is not searched until it expires.
# Off by default on the wire, so a daemon that never heard of the field cannot
# be assumed to honour it.
def RequestFileCache(): bool
  return get(g:, 'simplefinder_grep_cache', 1) != 0
    && simplefinder#core#HasCap('grep_cache')
enddef

def SendFilesRequest(query: string)
  if !PathGlobsReady()
    return
  endif
  if !EnsureBackend()
    return
  endif
  if AwaitNegotiation()
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
    threads: RequestThreads(),
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
    s_total_exact = true
    s_stream_id = 0
    s_elapsed_ms = 0
    PanelRender()
    return
  endif
  if !EnsureBackend()
    return
  endif
  if AwaitNegotiation()
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
    # Opting in per request rather than unconditionally keeps a daemon that
    # predates streaming on its single-reply path instead of relying on it to
    # ignore a field it has never heard of.
    stream: simplefinder#core#HasCap('stream'),
    file_cache: RequestFileCache(),
    threads: RequestThreads(),
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
    # Prefer the buffer number when the source recorded one.  An unnamed
    # buffer has no path at all, so a filename-only entry becomes bufnr 0 and
    # neither :cc nor <CR> in the list goes anywhere; AcceptItem already
    # resolves items this way round for exactly the same reason.
    var entry: dict<any> = {}
    var src_bufnr = get(item, 'bufnr', -1)
    if src_bufnr > 0 && bufexists(src_bufnr)
      entry.bufnr = src_bufnr
    else
      entry.filename = ResolvePath(item)
    endif
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
    SetQuery(query)
    FilterBuffers()
    return
  endif
  if mode ==# 'recent'
    RecentFiles()
    SetQuery(query)
    FilterRecentFiles()
    return
  endif
  if mode ==# 'lines'
    Lines()
    SetQuery(query)
    FilterLines()
    return
  endif
  if mode ==# 'help'
    HelpTags()
    SetQuery(query)
    FilterHelp()
    return
  endif
  if mode ==# 'gitfiles'
    GitFiles()
    SetQuery(query)
    FilterGitFiles()
    return
  endif
  if mode ==# 'list'
    # A picker's rows were collected once by whoever called Pick(); resuming
    # re-opens that same collection rather than guessing how to gather it again.
    Pick(extendnew({title: s_list_title, items: s_list_all, key: s_list_key},
      s_list_hooks))
    SetQuery(query)
    FilterList()
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
  if AwaitNegotiation()
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
    # A symbol search is a grep over the whole project, so it benefits from
    # partial batches — and from not re-walking the tree — exactly as much as
    # one the user typed.
    stream: simplefinder#core#HasCap('stream'),
    file_cache: RequestFileCache(),
    threads: RequestThreads(),
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
# Picker API and list sources
#
# Nine sources hardcoded into a nine-way switch is a plugin; one entry point
# that any of them could have been written against is something other people
# can build on.  A list source is a list of dicts: `display` is the row, and
# the field the fuzzy filter matches; the usual `path` / `bufnr` / `lnum` /
# `col` / `text` fields make that row a *location*, which is all that <CR>,
# the preview popup and the quickfix export need in order to work with no
# per-source code at all.  A source whose rows are not locations supplies its
# own Accept instead.
#
# The built-in marks, jumplist and quickfix sources below are written against
# this API rather than beside it, so it cannot quietly rot: they are as much a
# test of it as the tests are.
# =============================================================

var s_list_all: list<dict<any>> = []
var s_list_title: string = 'List'
var s_list_key: string = 'display'
# Vim reserves capital-initial names for funcref variables, which no `s_`
# prefix can satisfy, so the picker's callbacks live in a dict instead.
var s_list_hooks: dict<any> = {}

def AsString(value: any): string
  return type(value) == v:t_string ? value : ''
enddef

# spec:
#   title   string                 panel title                (default 'List')
#   items   list<dict<any>>        rows; see above
#   key     string                 which field to match on    (default 'display')
#   Accept  func(item, openmode)   what <CR> and friends do   (default: jump to
#                                  the item's location)
export def Pick(spec: dict<any>)
  var raw = get(spec, 'items', [])
  if type(raw) != v:t_list
    echohl ErrorMsg
    echom '[SimpleFinder] Pick(): items must be a list of dictionaries'
    echohl None
    return
  endif
  var items: list<dict<any>> = []
  for entry in raw
    if type(entry) != v:t_dict
      continue
    endif
    var item: dict<any> = copy(entry)
    # `display` is optional for the common case where the row is a path or a
    # line of text and repeating it would be noise.
    var display = AsString(get(item, 'display', ''))
    if display ==# ''
      display = AsString(get(item, 'text', ''))
    endif
    if display ==# ''
      display = AsString(get(item, 'path', ''))
    endif
    item.display = display
    add(items, item)
  endfor

  var title = AsString(get(spec, 'title', ''))
  s_list_title = title ==# '' ? 'List' : title
  var key = AsString(get(spec, 'key', ''))
  s_list_key = key ==# '' ? 'display' : key
  s_list_hooks = {}
  var Accept = get(spec, 'Accept', null_function)
  if type(Accept) == v:t_func && Accept != null_function
    s_list_hooks.Accept = Accept
  endif
  s_list_all = items

  AssignItemIdentities(s_list_all)
  PanelOpen('list')
  s_items = copy(s_list_all)
  s_total = len(s_items)
  PanelRender()
enddef

def FilterList()
  s_items = FuzzyFilterLocal(s_list_all, s_query, s_list_key)
  s_total = len(s_items)
  s_cursor_idx = 0
  s_scroll_off = 0
  PanelRender()
enddef

# The line a location points at, when it is cheap to know: only a loaded
# buffer is read, because a mark list spanning fifty files would otherwise
# open fifty files to draw one panel.
def LocationText(buf: number, lnum: number): string
  if buf <= 0 || lnum <= 0 || !bufloaded(buf)
    return ''
  endif
  return trim(get(getbufline(buf, lnum), 0, ''))
enddef

def LocationLabel(buf: number, path: string): string
  if path !=# ''
    return fnamemodify(path, ':~:.')
  endif
  if buf > 0 && bufname(buf) !=# ''
    return fnamemodify(bufname(buf), ':~:.')
  endif
  return buf > 0 ? printf('[buffer %d]', buf) : '[no file]'
enddef

# ─────────────────── Marks ───────────────────

export def Marks()
  if !exists('*getmarklist')
    echohl WarningMsg
    echom '[SimpleFinder] this Vim has no getmarklist()'
    echohl None
    return
  endif
  var src = bufnr('%')
  var items: list<dict<any>> = []
  # Buffer-local marks first: they are about where you are, and the file-wide
  # ones are a different kind of answer to the same question.
  for entry in getmarklist(src) + getmarklist()
    var name = substitute(AsString(get(entry, 'mark', '')), "^'", '', '')
    # '. '^ '" '[ '] '< '> are cursor bookkeeping, not places anyone set.
    if name !~# '^[A-Za-z0-9]$'
      continue
    endif
    var pos = get(entry, 'pos', [0, 0, 0, 0])
    if type(pos) != v:t_list || len(pos) < 3 || pos[1] <= 0
      continue
    endif
    var buf = pos[0]
    var file = AsString(get(entry, 'file', ''))
    # No expand() on a file name, for the same reason the preview does not use
    # one: it is a wildcard, environment-variable, %/#-special and backtick
    # expander, so a mark on a file called `lit$HOME.txt` resolved to a path
    # that does not exist.  fnamemodify(':p') resolves '~' and relative names,
    # which is all a getmarklist() 'file' value ever needs.
    var path = file ==# '' ? '' : fnamemodify(file, ':p')
    if buf <= 0 && path !=# ''
      buf = bufnr(path)
    endif
    var item: dict<any> = {lnum: pos[1], col: max([1, pos[2]])}
    if buf > 0 && bufexists(buf)
      item.bufnr = buf
    endif
    if path !=# ''
      item.path = path
    elseif buf > 0
      item.path = fnamemodify(bufname(buf), ':p')
    endif
    var text = LocationText(buf, pos[1])
    item.text = text
    item.display = printf('%-2s %s:%d  %s', name,
      LocationLabel(buf, AsString(get(item, 'path', ''))), pos[1], text)
    add(items, item)
  endfor
  Pick({title: 'Marks', items: items})
enddef

# ─────────────────── Jump list ───────────────────

export def Jumps()
  var jumps = getjumplist()[0]
  var items: list<dict<any>> = []
  # Newest first: the jump you want back to is nearly always a recent one.
  for entry in reverse(copy(jumps))
    var buf = get(entry, 'bufnr', 0)
    if buf <= 0 || !bufexists(buf)
      continue
    endif
    var lnum = get(entry, 'lnum', 0)
    var text = LocationText(buf, lnum)
    var name = bufname(buf)
    add(items, {
      bufnr: buf,
      path: name ==# '' ? '' : fnamemodify(name, ':p'),
      lnum: lnum,
      col: max([1, get(entry, 'col', 0) + 1]),
      text: text,
      display: printf('%s:%d  %s', LocationLabel(buf, ''), lnum, text),
    })
  endfor
  Pick({title: 'Jumps', items: items})
enddef

# ─────────────────── Quickfix and location lists ───────────────────

# Fuzzy-find inside a list you already have.  A 400-entry quickfix list from a
# project-wide grep is exactly the thing :cnext is bad at.
export def QuickfixList(location: bool = false)
  var win = win_getid()
  var raw = location ? getloclist(win) : getqflist()
  var what = location
    ? getloclist(win, {title: 1})
    : getqflist({title: 1})
  var items: list<dict<any>> = []
  for entry in raw
    var buf = get(entry, 'bufnr', 0)
    var lnum = get(entry, 'lnum', 0)
    var text = trim(AsString(get(entry, 'text', '')))
    var name = buf > 0 && bufexists(buf) ? bufname(buf) : ''
    var item: dict<any> = {
      lnum: lnum,
      col: max([1, get(entry, 'col', 0)]),
      text: text,
      display: lnum > 0
        ? printf('%s:%d  %s', LocationLabel(buf, ''), lnum, text)
        : text,
    }
    if buf > 0 && bufexists(buf)
      item.bufnr = buf
    endif
    if name !=# ''
      item.path = fnamemodify(name, ':p')
    endif
    add(items, item)
  endfor
  var title = AsString(get(what, 'title', ''))
  Pick({
    title: (location ? 'Location list' : 'Quickfix') .. (title ==# '' ? '' : ': ' .. title),
    items: items,
  })
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

  # A picker source may act on its own items -- that is what makes the API
  # worth having.  It runs after the panel has closed and focus is back in the
  # source window, so the callback sees the editing context the user chose from.
  if s_mode ==# 'list' && has_key(s_list_hooks, 'Accept')
    var Accept = s_list_hooks.Accept
    try
      Accept(item, mode)
    catch
      echohl WarningMsg | echomsg 'simplefinder: ' .. v:exception | echohl None
    endtry
    return
  endif
  if s_mode ==# 'list' && path ==# '' && get(item, 'bufnr', 0) <= 0
    # Nothing to open and nobody to tell: a display-only picker.
    return
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
