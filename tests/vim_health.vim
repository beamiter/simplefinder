" :SimpleFinderHealth has to diagnose, and configuration has to be checked.
"
" Health is the first thing a user runs when something is wrong and the first
" thing that lands in a bug report, so a wrong fact in it costs more than a
" missing one.  On a fresh session it opened with `[ERROR] daemon` and
" `[ERROR] state: not running` -- both true and both meaningless, because the
" daemon starts with the first search.  It also had nothing to say about the
" two failures that actually happen: a binary left behind by an upgrade, and a
" mistyped option, which is pure silence otherwise since every reader of an
" option falls back to its default.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim_health.vim

set nocompatible
set nomore
set lines=40

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)
call delete(s:root .. '/tests/health-errors.log')

let s:daemon = s:root .. '/target/debug/simplefinder-daemon'
if !executable(s:daemon)
  let s:daemon = s:root .. '/lib/simplefinder-daemon'
endif
if !executable(s:daemon)
  " A checkout without a built daemon should not fail the suite.
  qall!
endif

let g:simplefinder_daemon_path = s:daemon
let g:simplefinder_preview = 0
runtime plugin/simplefinder.vim

function! s:Report() abort
  call simplefinder#Health()
  let l:lines = getline(1, '$')
  return l:lines
endfunction

function! s:Section(lines, title) abort
  let l:out = []
  let l:inside = 0
  for l:line in a:lines
    if l:line ==# a:title
      let l:inside = 1
    elseif l:inside && l:line =~# '^[A-Z]\+$'
      break
    elseif l:inside && l:line !=# ''
      call add(l:out, l:line)
    endif
  endfor
  return l:out
endfunction

" The optional third argument is a longer budget, for the waits that are
" waiting on a deadline in the plugin rather than on a binary that answers.
function! s:WaitFor(Cond, label, ...) abort
  for l:attempt in range(a:0 ? a:1 : 300)
    if call(a:Cond, [])
      return 1
    endif
    sleep 10m
  endfor
  call assert_true(0, 'timeout: ' .. a:label)
  return 0
endfunction

" ValidateConfig() is reached through these two rather than called directly.
" In -es mode Vim reports an error and steps over the line that raised it, so
" calling it inline from an assert_match() argument against a build that has no
" such function records nothing whatsoever -- an assertion that cannot fail.
" Turning the exception into a failure is what makes the checks below mean
" something.
function! s:Problems() abort
  try
    return simplefinder#ValidateConfig()
  catch
    call assert_true(0, 'simplefinder#ValidateConfig(): ' .. v:exception)
    return ['<no diagnosis>']
  endtry
endfunction

function! s:ProblemText() abort
  return join(s:Problems(), "\n")
endfunction

" ── The defaults are a clean bill of health ──
call assert_equal([], s:Problems(),
      \ 'every documented option, at its default, is a value the plugin accepts')

" ── The report never lands on somebody else's buffer ──
"
" This has to run before anything else opens the report, because the hazard is
" on the create path: the report used to be opened by name, and
" `:split SimpleFinderHealth` binds the window to that *file name*.  In a
" directory that happens to hold a file so called, the buffer editing it was
" emptied, forced to 'buftype=nofile' so it could no longer be written back,
" and had 'modified' cleared -- unsaved work gone, silently.
let s:decoy_dir = s:root . '/tests/health-decoy'
call delete(s:decoy_dir, 'rf')
call mkdir(s:decoy_dir, 'p')
call writefile(['important note'], s:decoy_dir . '/SimpleFinderHealth')
let s:cwd = getcwd()
execute 'lcd ' . fnameescape(s:decoy_dir)
edit SimpleFinderHealth
call setline(2, 'UNSAVED EDIT')
let s:decoy = bufnr('%')
SimpleFinderHealth
let s:report = bufnr('%')
call assert_notequal(s:decoy, s:report,
      \ 'the report opens a buffer of its own, not whatever the name resolved to')
call assert_equal('nofile', &buftype, 'and that buffer is still the scratch report')
call assert_equal('', bufname('%'),
      \ 'the name is that other buffer''s, so :file fails with E95 and the report '
      \ . 'stays unnamed rather than take it -- which reads exactly the same')
call assert_match('SimpleFinder health', getline(1), 'holding the report itself')
call assert_equal(['important note', 'UNSAVED EDIT'], getbufline(s:decoy, 1, '$'),
      \ 'a file that happens to be called SimpleFinderHealth keeps its contents')
call assert_equal('', getbufvar(s:decoy, '&buftype'),
      \ 'and stays a file buffer, so it can still be written back')
call assert_true(getbufvar(s:decoy, '&modified'),
      \ 'and keeps the unsaved edit that would otherwise be lost without a word')
close
execute 'lcd ' . fnameescape(s:cwd)
execute 'bwipeout! ' . s:decoy
" The report above is kept for the rest of the session, and it is the one that
" had to go unnamed; wipe it so the next :SimpleFinderHealth builds a report on
" the ordinary path, where the name is free.
execute 'bwipeout! ' . s:report
call delete(s:decoy_dir, 'rf')

" ── A fresh session is not a broken one ──
let s:lines = s:Report()
call assert_equal('nofile', &buftype, 'the report is a scratch buffer')
" Naming is the last step of building the report -- the buffer is created
" empty and unnamed precisely so it can collide with nothing -- and the name is
" what makes the window recognisable in :ls! and in the status line.
call assert_equal('SimpleFinderHealth', bufname('%'),
      \ 'a report that can have the documented name takes it')
call assert_false(&modifiable, 'the report is not editable')
for s:title in ['ENVIRONMENT', 'BINARY', 'CONFIG', 'RUNTIME', 'CONTEXT']
  call assert_notequal(-1, index(s:lines, s:title), s:title .. ' is always reported')
endfor

let s:runtime = s:Section(s:lines, 'RUNTIME')
call assert_equal(1, len(s:runtime), 'a daemon that was never started is one fact')
call assert_match('not started yet', s:runtime[0],
      \ 'the daemon starts with the first search, so before then this is not a fault')
call assert_notmatch('ERROR', s:runtime[0],
      \ 'reporting the expected state as an error sends every bug report down a blind alley')
call assert_match('every option holds a value', join(s:Section(s:lines, 'CONFIG'), "\n"))

" The version is probed with job_start, so the first report says `probing…`
" and fills itself in; a synchronous probe would hang on exactly the wedged
" binary this command exists to diagnose.
call s:WaitFor({-> join(s:Report(), "\n") !~# 'probing'}, 'the version probe lands')
call assert_match('\[OK\] version: \d\+\.\d\+\.\d\+',
      \ join(s:Section(s:Report(), 'BINARY'), "\n"),
      \ 'a binary that matches the plugin is reported as such')

" ── A binary left behind by an upgrade is what this command exists for ──
"
" The plugin manager pulls new Vim files and new Rust sources and nothing
" rebuilds lib/.  Everything then works well enough to look healthy while a
" capability the help documents is quietly missing, so the only way to see it
" is to compare what the binary says it is against what the Vim files beside
" it were shipped as.
let s:shim = s:root .. '/tests/stale-daemon.sh'
call writefile(['#!/bin/sh', 'echo "simplefinder-daemon 0.0.1"'], s:shim)
call setfperm(s:shim, 'rwxr-xr-x')
let g:simplefinder_daemon_path = s:shim
call s:WaitFor({-> join(s:Report(), "\n") !~# 'probing'}, 'the stale binary answers')
call assert_match('\[ERROR\] version: daemon 0\.0\.1, plugin \d\+\.\d\+\.\d\+',
      \ join(s:Section(s:Report(), 'BINARY'), "\n"),
      \ 'a daemon that does not match the plugin is the upgrade that only half happened')
let g:simplefinder_daemon_path = s:daemon
call delete(s:shim)
call s:WaitFor({-> join(s:Report(), "\n") !~# 'probing'}, 'the real binary answers again')

" ── A binary that answers nothing still has to end in a verdict ──
"
" This is the failure the whole command was written for, and the one the async
" probe cannot see by itself: against a wedged binary job_start() succeeds and
" exit_cb never arrives, so without a deadline the line reads `probing…` for
" the rest of the session and the one user who is certain something is wrong
" gets no fact at all.  The report is read straight out of the buffer here, so
" the redraw-in-place is on trial as well as the deadline.
function! s:Buffer() abort
  return join(getline(1, '$'), "\n")
endfunction

let s:wedged = s:root .. '/tests/wedged-daemon.sh'
call writefile(['#!/bin/sh', 'sleep 600'], s:wedged)
call setfperm(s:wedged, 'rwxr-xr-x')
let g:simplefinder_daemon_path = s:wedged
call s:Report()
call assert_match('\[INFO\] version: probing…', s:Buffer(),
      \ 'the probe is asynchronous, so the command itself never hangs')
call s:WaitFor({-> s:Buffer() !~# 'probing'}, 'the wedged binary is given up on', 800)
call assert_match('\[ERROR\] version: the binary did not answer --version within \d\+s',
      \ join(s:Section(split(s:Buffer(), "\n"), 'BINARY'), "\n"),
      \ 'a binary that never answers has to end in a verdict, not in probing…')

" A deadline that fired is a verdict, not an answer: running the command again
" is asking for another attempt, and it has to get one -- otherwise a machine
" that was thrashing for one moment carries the red line until Vim restarts.
call assert_match('\[INFO\] version: probing…', join(s:Report(), "\n"),
      \ 'a timed-out probe is tried again when the user asks again')

let g:simplefinder_daemon_path = s:daemon
call delete(s:wedged)
call s:WaitFor({-> join(s:Report(), "\n") !~# 'probing'},
      \ 'the real binary answers after the wedged one', 800)
call assert_match('\[OK\] version: \d\+\.\d\+\.\d\+',
      \ join(s:Section(s:Report(), 'BINARY'), "\n"),
      \ 'a probe still in flight does not own the report once the binary changes')

" ── Once the daemon is up, the report says so ──
"
" The same first search also carries the one-off configuration check: health
" has to be opened to be read, so a setting that will never do anything is said
" out loud where the user already is.  Once, though -- a search is not the
" place to be nagged, and the WARN lines stay in the report.
let g:simplefinder_root = s:root
let g:simplefinder_panel_wdith = 40
SimpleFinderFiles
call s:WaitFor({-> simplefinder#core#IsRunning()}, 'the daemon starts')
call feedkeys("\<Esc>", 'xt')
let s:runtime = s:Section(s:Report(), 'RUNTIME')
call assert_match('running', join(s:runtime, "\n"), 'a started daemon is reported running')
call assert_notmatch('not started yet', join(s:runtime, "\n"))

function! s:Nagged() abort
  return len(filter(split(execute('messages'), "\n"), 'v:val =~# "simplefinder_panel_wdith"'))
endfunction
call assert_equal(1, s:Nagged(), 'the option that can never do anything is named at the first search')
SimpleFinderFiles
call feedkeys("\<Esc>", 'xt')
call assert_equal(1, s:Nagged(), 'and not again for the rest of the session')
unlet g:simplefinder_panel_wdith
call simplefinder#Stop()

" ── Configuration problems are named, with the value that caused them ──
let g:simplefinder_position = 'middle'
call assert_match("g:simplefinder_position = middle is not one of left/right",
      \ s:ProblemText())
let g:simplefinder_position = 'right'

let g:simplefinder_panel_width = '50'
call assert_match('g:simplefinder_panel_width = 50 is not a number',
      \ s:ProblemText(),
      \ 'a quoted number is the classic vimrc slip and must be named as one')
" The floor is EnsurePanel()'s own clamp, min([max([width, 24]), ...]), not a
" number invented here: a report that called 15 acceptable would be describing
" a panel width the plugin never opens.
let g:simplefinder_panel_width = 5
call assert_match('is below the minimum 24', s:ProblemText())
call assert_match('the panel opens at 24 columns',
      \ s:ProblemText(),
      \ 'a clamped value is a warning that says what it was clamped to')
let g:simplefinder_panel_width = 50

" ── A value the plugin honours is never an [ERROR] ──
"
" [ERROR] and [WARN] are not decoration: [ERROR] means the value cannot be used
" as written, and those are the lines CheckConfigOnce() echoes in WarningMsg in
" front of the first search of the session.  A floor the plugin simply clamps
" is the documented [WARN] case, so reporting one as an [ERROR] nags a user
" whose setting is doing precisely what they asked for.  Each pair below is the
" clamp in the plugin, quoted: `max([0, ...])` for history_max, `if wanted > 0`
" for preview_width and `max_bytes > 0 &&` for preview_max_bytes -- in all
" three a value below the floor behaves exactly as 0 does.
for s:case in [
      \ ['history_max', -1, 50, 'no query is remembered'],
      \ ['preview_width', -5, 0, 'the preview picks its own width'],
      \ ['preview_max_bytes', -1, 2097152, 'no size limit is applied']]
  execute 'let g:simplefinder_' . s:case[0] . ' = ' . s:case[1]
  let s:text = s:ProblemText()
  call assert_notmatch('\[ERROR\] g:simplefinder_' . s:case[0], s:text,
        \ s:case[0] . ': a value the plugin clamps is used, so it is not an error')
  call assert_match('\[WARN\] g:simplefinder_' . s:case[0] . ' = ' . s:case[1]
        \ . ' is below the minimum 0; ' . s:case[3], s:text,
        \ s:case[0] . ': a clamped value is a warning that says what it was clamped to')
  execute 'let g:simplefinder_' . s:case[0] . ' = ' . s:case[2]
endfor

let g:simplefinder_root_markers = ['.git', 42]
call assert_match('every entry must be a non-empty string',
      \ s:ProblemText())
let g:simplefinder_root_markers = ['.git']

let g:simplefinder_symbol_keywords = {'rust': ['fn', '']}
call assert_match('every keyword must be a non-empty string',
      \ s:ProblemText())
let g:simplefinder_symbol_keywords = {}

let g:simplefinder_root = s:root .. '/no-such-directory'
call assert_match('is not a directory', s:ProblemText())
let g:simplefinder_root = ''

let g:simplefinder_ignore_case = 1
call assert_match('overrides g:simplefinder_smart_case',
      \ s:ProblemText())
let g:simplefinder_ignore_case = 0

" A misspelled option is the failure with no symptom at all: the plugin reads
" its default and the setting the user did write does nothing, for ever.
let g:simplefinder_panel_wdith = 40
call assert_match('g:simplefinder_panel_wdith is not a SimpleFinder option',
      \ s:ProblemText())
unlet g:simplefinder_panel_wdith

" ...but a variable belonging to something else is not ours to complain about.
let g:simplefinder = 1
let g:loaded_simplefinder = 1
call assert_equal([], s:Problems(),
      \ 'only names this plugin owns are checked')
unlet g:simplefinder

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/health-errors.log')
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit
endif
qall!
