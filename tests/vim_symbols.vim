" Project-wide symbol search.
"
" Definitions are found by grepping for language keywords, so there is no tags
" file or language server involved and nothing to set up. The parts worth
" pinning down are that the keyword set follows the *source* buffer's filetype
" (reading it after the panel opens silently searched every language), that a
" query narrows the results, and that regex metacharacters a user types cannot
" break the pattern we assemble.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim_symbols.vim

set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)
call delete(s:root .. '/tests/symbols-errors.log')

let s:daemon = s:root . '/lib/simplefinder-daemon'
if !executable(s:daemon)
  let s:daemon = s:root . '/target/debug/simplefinder-daemon'
endif
if !executable(s:daemon)
  " A checkout without a built daemon should not fail the suite.
  qall!
endif
let g:simplefinder_daemon_path = s:daemon
let g:simplefinder_close_on_select = 0
filetype plugin indent on
runtime plugin/simplefinder.vim

" ---------------------------------------------------------------- fixture ---

let s:proj = tempname()
call mkdir(s:proj, 'p')
call writefile([], s:proj . '/.git')
call writefile([
      \ 'fn alpha_function() {}',
      \ 'struct AlphaStruct;',
      \ 'const ALPHA_CONST: u8 = 1;',
      \ 'let not_a_rust_definition = 1;',
      \ 'fn needle_target(arg: u8) {}',
      \ ], s:proj . '/lib.rs')
call writefile([
      \ 'def beta_function():',
      \ '    pass',
      \ 'class BetaClass:',
      \ '    pass',
      \ ], s:proj . '/mod.py')
call writefile([
      \ 'let vimscript_variable = 1',
      \ 'function! VimFunction()',
      \ 'endfunction',
      \ ], s:proj . '/thing.vim')

let g:simplefinder_root = s:proj

function! s:Wait(ms) abort
  let l:i = 0
  while l:i < a:ms / 20
    sleep 20m
    let l:i += 1
  endwhile
endfunction

function! s:Panel() abort
  return join(getbufline(bufnr('SimpleFinder'), 1, '$'), "\n")
endfunction

" Open a source file so the filetype is real, then run the search from it.
function! s:Search(file, query) abort
  execute 'edit ' . fnameescape(s:proj . '/' . a:file)
  execute 'SimpleFinderSymbols' . (a:query ==# '' ? '' : ' ' . a:query)
  call s:Wait(900)
  return s:Panel()
endfunction

" -------------------------------------------------------- filetype scoping ---

let s:rust = s:Search('lib.rs', '')
call assert_true(s:rust =~# 'alpha_function', 'a Rust fn is found')
call assert_true(s:rust =~# 'AlphaStruct', 'a Rust struct is found')
call assert_true(s:rust =~# 'ALPHA_CONST', 'a Rust const is found')

" The keyword set must come from the source buffer. Reading &filetype after
" the panel opened saw the panel's own buffer, fell through to every language,
" and matched `let` -- which is not a Rust definition keyword.
call assert_false(s:rust =~# 'not_a_rust_definition',
      \ 'a Rust search does not match another language''s keywords')
call assert_false(s:rust =~# 'beta_function',
      \ 'a Rust search does not match Python definitions')

let s:py = s:Search('mod.py', '')
call assert_true(s:py =~# 'beta_function', 'a Python def is found')
call assert_true(s:py =~# 'BetaClass', 'a Python class is found')
call assert_false(s:py =~# 'alpha_function', 'a Python search excludes Rust fns')

" ---------------------------------------------------------------- querying ---

let s:narrow = s:Search('lib.rs', 'needle')
call assert_true(s:narrow =~# 'needle_target', 'a query finds the matching definition')
call assert_false(s:narrow =~# 'alpha_function', 'a query excludes non-matching definitions')

" ------------------------------------------------------- metacharacters ---

" A query is user text, not regex source. These would be a syntax error or
" would match the wrong thing if they reached the pattern unescaped.
for s:bad in ['needle(', 'a|b', 'x*', '[unclosed', 'a+b', 'dot.']
  execute 'edit ' . fnameescape(s:proj . '/lib.rs')
  execute 'SimpleFinderSymbols ' . s:bad
  call s:Wait(500)
  call assert_false(s:Panel() =~# 'error',
        \ 'a query containing ' . s:bad . ' must not break the pattern')
endfor

" ------------------------------------------------------------- overrides ---

" A user-supplied keyword set replaces the built-in one for that filetype.
let g:simplefinder_symbol_keywords = {'rust': ['struct']}
let s:only_struct = s:Search('lib.rs', '')
call assert_true(s:only_struct =~# 'AlphaStruct', 'the override still finds structs')
call assert_false(s:only_struct =~# 'alpha_function',
      \ 'the override replaces the built-in keyword set')
unlet g:simplefinder_symbol_keywords

" Searching every language at once is what a polyglot repository wants.
let g:simplefinder_symbol_all_languages = 1
let s:all = s:Search('lib.rs', '')
call assert_true(s:all =~# 'alpha_function', 'all-languages still finds Rust')
call assert_true(s:all =~# 'beta_function', 'all-languages reaches Python too')
let g:simplefinder_symbol_all_languages = 0

" ---------------------------------------------------------------- resume ---

call s:Search('lib.rs', 'needle')
SimpleFinderResume
call s:Wait(700)
call assert_true(s:Panel() =~# 'Symbols', 'resume restores the symbols source')
call assert_true(s:Panel() =~# 'needle_target', 'resume restores the query')

" ------------------------------------------------------------------ done ---

call simplefinder#Stop()
call delete(s:proj, 'rf')

if len(v:errors)
  call writefile(v:errors, s:root . '/tests/symbols-errors.log')
  for s:e in v:errors
    echomsg s:e
  endfor
  cquit
endif
qall!
