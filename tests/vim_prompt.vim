" The query is an editable prompt, not an append-only buffer.
"
" Every edit used to land at the end of the query: fixing a typo in the middle
" of a pattern meant deleting everything after it, there was no way to paste
" the identifier you had just yanked, and the pattern you ran a minute ago was
" gone for good.  The block glyph is the query cursor, so these assertions read
" the prompt line whole -- text *and* cursor position in one string.
"
" All of it runs over the pure-Vim `lines` and `help` sources, so no daemon is
" involved and nothing here can race.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim_prompt.vim

set nocompatible
set nomore
set encoding=utf-8

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)
call delete(s:root .. '/tests/prompt-errors.log')

let g:simplefinder_preview = 0
let g:simplefinder_close_on_select = 0
runtime plugin/simplefinder.vim

" The prompt line, cursor glyph included: ' > <before>▁<after>'.
function! s:Prompt() abort
  let l:buf = bufnr('SimpleFinder')
  return l:buf <= 0 ? '' : matchstr(get(getbufline(l:buf, 2), 0, ''), '^ > \zs.*')
endfunction

enew
call setline(1, ['alpha bravo', 'charlie delta', 'echo foxtrot'])
setlocal nomodified

" ------------------------------------------------------ cursor and editing ---

SimpleFinderLines
call feedkeys('abc', 'xt')
call assert_equal("abc▁", s:Prompt(), 'typing appends at the end')

call feedkeys("\<Left>\<Left>X", 'xt')
call assert_equal("aX▁bc", s:Prompt(), 'a character is inserted at the cursor')

call feedkeys("\<BS>", 'xt')
call assert_equal("a▁bc", s:Prompt(), 'backspace deletes before the cursor, not at the end')

call feedkeys("\<Home>Z", 'xt')
call assert_equal("Z▁abc", s:Prompt(), '<Home> moves to the start of the query')

call feedkeys("\<End>!", 'xt')
call assert_equal("Zabc!▁", s:Prompt(), '<End> moves back to the end')

call feedkeys("\<C-u>foo bar\<Left>\<Left>\<C-w>", 'xt')
call assert_equal("foo ▁ar", s:Prompt(),
      \ '<C-w> deletes the word before the cursor and keeps the rest')

" Sitting on a word boundary, <C-w> takes the preceding word with its trailing
" whitespace, as it does on Vim's own command line.
call feedkeys("\<C-u>foo bar\<Left>\<Left>\<Left>\<C-w>", 'xt')
call assert_equal("▁bar", s:Prompt(), '<C-w> swallows the whitespace before the word')

" ------------------------------------------------------------ register paste ---

" A register is the shortest route to text the panel cannot receive as
" keystrokes: it maps one key per printable ASCII character, so a CJK
" identifier can be yanked into the query but never typed into it.
let @z = '中文'
call feedkeys("\<C-u>fn \<C-y>z", 'xt')
call assert_equal("fn 中文▁", s:Prompt(), 'a register is spliced in at the cursor')

" A linewise register holds several lines and a trailing newline; a query is
" one line.
let @q = "one\ntwo\n"
call feedkeys("\<C-u>\<C-y>q", 'xt')
call assert_equal("one two▁", s:Prompt(), 'a multi-line register is joined')

" An unknown register name is a typo, not an error: the query is left alone.
call feedkeys("\<C-u>keep\<C-y>\<Esc>", 'xt')
call assert_equal("keep▁", s:Prompt(), 'cancelling the register prompt changes nothing')

" Terminal bracketed paste bypasses mappings and asks Vim to insert the whole
" payload literally.  It must still become query text even though the cursor
" currently follows a result row rather than sitting on the prompt line.
call feedkeys("\<C-u>pre ", 'xt')
let s:paste_line = line('.')
let s:paste_tail = getline(s:paste_line)
call setline(s:paste_line, '中文 target')
call append(s:paste_line, 'two' .. s:paste_tail)
call simplefinder#OnPanelTextChanged()
call assert_equal("pre 中文 target two▁", s:Prompt(),
      \ 'direct terminal paste is spliced into the query and joined to one line')

" ------------------------------------------------------------------ history ---

call feedkeys("\<C-u>delta\<Esc>", 'xt')
SimpleFinderLines
call feedkeys("echo\<Esc>", 'xt')

SimpleFinderLines
call assert_equal("▁", s:Prompt(), 'a new panel starts empty')
call feedkeys("\<C-Up>", 'xt')
call assert_equal("echo▁", s:Prompt(), '<C-Up> recalls the most recent query')
call feedkeys("\<C-Up>", 'xt')
call assert_equal("delta▁", s:Prompt(), 'another <C-Up> goes further back')
call feedkeys("\<C-Up>", 'xt')
call assert_equal("delta▁", s:Prompt(), 'the oldest entry is the end of the list')
call feedkeys("\<C-Down>", 'xt')
call assert_equal("echo▁", s:Prompt(), '<C-Down> walks back towards the present')
call feedkeys("\<C-Down>", 'xt')
call assert_equal("▁", s:Prompt(), 'the last step restores the query recall started from')

" History is per source: a buffer-line query is not a help-tag query.
SimpleFinderHelp
call feedkeys("\<C-Up>", 'xt')
call assert_equal("▁", s:Prompt(), 'another source does not inherit the history')
call feedkeys("\<Esc>", 'xt')

" Re-running an old query moves it to the front rather than duplicating it.
SimpleFinderLines
call feedkeys("\<C-u>delta\<Esc>", 'xt')
SimpleFinderLines
call feedkeys("\<C-Up>", 'xt')
call assert_equal("delta▁", s:Prompt(), 'the repeated query is the most recent one')
call feedkeys("\<C-Up>", 'xt')
call assert_equal("echo▁", s:Prompt(), 'and it appears only once in the list')
call feedkeys("\<Esc>", 'xt')

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/prompt-errors.log')
  for s:error in v:errors
    echomsg s:error
  endfor
  cquit
endif
qall!
