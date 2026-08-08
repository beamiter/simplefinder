# SimpleFinder

SimpleFinder 是一个面向 Vim 9 的轻量、快速项目查找器。Vim9 负责原生侧边面板和交互，Rust 常驻进程负责并行文件扫描、模糊排序和全文检索。

## 特性

- 智能项目根识别，支持手动固定根目录
- 基于 `nucleo-matcher` 的文件名模糊搜索，并行文件扫描，命中字符高亮
- 并行项目全文搜索，支持纯文本、正则、smart-case，匹配片段高亮，跳过二进制文件
- 全文搜索结果流式返回：遍历尚未结束就先画出已找到的匹配，标题显示
  `12 results · searching…`；每批都是完整有序的快照，不会在结束时重排
- 预览弹窗：实时预览选中文件或匹配行上下文（`<C-e>` 开关）；按 filetype 高亮，
  可上下滚动，文件已在 buffer 里打开时读 buffer（未保存的修改也能正确预览）
- 多选标记 + 一键导出 quickfix 列表
- `:SimpleFinderResume` 恢复上次搜索（模式、查询、选项）
- 遵循 `.gitignore`，并可即时切换隐藏文件和忽略规则
- 原生 include/exclude 路径 glob，同时约束文件、全文和符号搜索
- 文件列表缓存、请求防抖和旧请求取消
- 文件、最近文件、缓冲区、光标词和可视选择搜索
- 编辑、水平/垂直分屏和新标签页打开；缓冲区模式可直接关闭 buffer
- 清晰的加载、错误、耗时、结果上限和空状态反馈

## 要求与安装

- Vim 9.0+，需包含 `+job`、`+channel`、`+timers`、`+textprop`、`+popupwin`
- Rust 1.88+（仅编译时需要）

把仓库加入 `runtimepath` 后执行：

```bash
./install.sh
```

使用 vim-plug 时：

```vim
Plug 'your-name/simplefinder', { 'do': './install.sh' }
```

## 命令

| 命令 | 作用 |
| --- | --- |
| `:SimpleFinderFiles [query]` | 查找项目文件 |
| `:SimpleFinderGrep [text]` | 搜索项目文本 |
| `:SimpleFinderIGrep [text]` | 打开实时全文搜索 |
| `:SimpleFinderGrepWord` | 搜索光标下单词 |
| `:SimpleFinderGrepVisual` | 搜索当前可视选择 |
| `:SimpleFinderBuffers` | 查找已打开缓冲区 |
| `:SimpleFinderRecent` | 查找最近文件 |
| `:SimpleFinderLines` | 模糊搜索当前缓冲区的行 |
| `:SimpleFinderHelp` | 模糊搜索帮助标签并打开 `:help` |
| `:SimpleFinderSymbols [query]` | 无需 tags/LSP 搜索项目定义 |
| `:SimpleFinderGitFiles` | 基于 Git 索引查找 tracked/untracked 文件 |
| `:SimpleFinderResume` | 恢复上次搜索（模式、查询、选项） |
| `:SimpleFinderMarks` | 模糊搜索标记(当前 buffer 的 a-z,以及 A-Z / 0-9) |
| `:SimpleFinderJumps` | 模糊搜索跳转表 |
| `:SimpleFinderQuickfix` / `:SimpleFinderLoclist` | 在 quickfix / location list 里模糊查找 |
| `:SimpleFinderRoot [dir]` | 查看或设置固定搜索根目录 |

每个命令都有对应的 `<Plug>` 目标,推荐绑定 `<Plug>` 而不是命令名:

```vim
nmap <leader>ff <Plug>(simplefinder-files)
nmap <leader>fg <Plug>(simplefinder-igrep)
nmap <leader>fb <Plug>(simplefinder-buffers)
nmap <leader>fw <Plug>(simplefinder-grep-word)
nmap <leader>fr <Plug>(simplefinder-resume)
xmap <leader>fg <Plug>(simplefinder-grep-visual)
```

其余可用目标:`-gitfiles`、`-grep`、`-recent`、`-lines`、`-help`、`-symbols`、
`-marks`、`-jumps`、`-quickfix`、`-loclist`。

可视模式请用 `<Plug>(simplefinder-grep-visual)`,不要自行绑定。它必须在可视模式
仍然生效时运行才能读到当前选区：`'<` / `'>` 标记要等选区结束才写入,自己写的
映射很容易搜成上一次的选区。`:'<,'>SimpleFinderGrepVisual` 命令形式没有活动选区
可读,仍按标记工作。

## 面板按键

| 按键 | 作用 |
| --- | --- |
| `<CR>` | 编辑当前结果 |
| `<C-v>` / `<C-x>` / `<C-t>` | 垂直分屏 / 水平分屏 / 标签页打开 |
| `<C-j>` / `<C-k>` | 下一个 / 上一个结果 |
| `<Tab>` / `<S-Tab>` | 标记/取消标记当前结果并下移/上移(多选) |
| `<C-q>` | 将标记结果(无标记时为全部)导出到 quickfix |
| `<C-l>` | 将标记结果(无标记时为全部)导出到启动 split 的 location list |
| `<C-e>` | 开关预览弹窗 |
| `<PageDown>` / `<PageUp>` | 滚动预览(相对当前匹配,换结果即复位) |
| `<C-u>` / `<C-w>` | 清空查询 / 删除光标前的一个词 |
| `<Left>` / `<Right>` / `<Home>` / `<End>` | 在查询里移动光标(提示行的方块就是光标) |
| `<C-y>{reg}` | 把寄存器粘到光标处(多行寄存器按空格拼接) |
| `<C-f>` | 在命令行上编辑查询(带上所有输入法) |
| `<C-Up>` / `<C-Down>` | 按来源回溯 / 前进查询历史 |
| `<C-r>` | 在全文搜索中切换纯文本/正则 |
| `<C-a>` | 循环大小写模式:smart `[sC]` → 忽略 `[aa]` → 敏感 `[Aa]` |
| `<C-o>` | 切换隐藏文件 |
| `<C-g>` | 切换是否遵循忽略文件 |
| `<C-d>` | 缓冲区模式:关闭选中 buffer |
| `<Esc>` | 关闭面板 |

Location-list export captures both the launching window ID and buffer. If
that split is closed, reused, or separated from the panel into another tab,
SimpleFinder keeps the panel focused and reports the stale target instead of
updating another editing context.

Marks follow stable result identities rather than screen indices. Continuing
to type, toggling search options, or receiving reordered asynchronous results
cannot move a mark onto an unrelated row. A row hidden by the current query
keeps its complete snapshot and is exported in first-mark order. Unmarking
releases that snapshot; closing the panel clears the entire selection, so
`:SimpleFinderResume` never revives invisible old marks.

## 配置

以下是默认值；请在插件加载前覆盖：

```vim
let g:simplefinder_max_results = 200
let g:simplefinder_debounce_ms = 50
let g:simplefinder_panel_width = 50
let g:simplefinder_position = 'right'       " 'left' 或 'right'
let g:simplefinder_close_on_select = 1
let g:simplefinder_preview = 1              " 默认开启预览弹窗
let g:simplefinder_preview_syntax = 1       " 预览按 filetype 高亮
let g:simplefinder_preview_width = 0        " 0 = 用满面板旁边的列
let g:simplefinder_preview_max_bytes = 2097152
let g:simplefinder_preview_cache = 4        " 缓存最近几个文件的内容
let g:simplefinder_history_max = 50         " 每个来源保留的历史查询条数
let g:simplefinder_lines_max = 50000        " :SimpleFinderLines 读取的行数上限
let g:simplefinder_hidden = 0
let g:simplefinder_no_ignore = 0
let g:simplefinder_regex = 0
let g:simplefinder_smart_case = 1           " 查询含大写字母时才区分大小写
let g:simplefinder_ignore_case = 0
let g:simplefinder_recent_files_max = 100
let g:simplefinder_root = ''                " 留空时自动识别
let g:simplefinder_root_markers = ['.git', 'Cargo.toml', 'package.json', 'go.mod']
let g:simplefinder_include_globs = []        " 如 ['*.rs', '*.toml']
let g:simplefinder_exclude_globs = []        " 如 ['vendor/**', '*.generated.rs']
let g:simplefinder_daemon_path = ''         " 通常无需设置
let g:simplefinder_debug = 0
```

项目根会从当前文件目录向上查找标记；没有匹配时使用当前工作目录。扫描默认遵循 `.ignore`、`.gitignore`、全局 Git ignore 和 `.git/info/exclude`。

匹配数超过 `g:simplefinder_max_results` 时，grep 保留 (path, lnum, col) 排序中最靠前
的那一批——与完整排序后截断的结果集相同——所以只要走完整棵树，同一查询每次返回同一批
结果，`<C-q>` 导出的 quickfix 也是确定的。面板同时显示两个数字，如 `200/5312 results`。
为了让总数可信，daemon 会继续统计到 `g:simplefinder_max_results` 的 50 倍(至少 10000)
为止；`.` 这类正则会立刻触顶。触顶会直接结束遍历，所以此后两个数字都不完整：总数是
下界，保留的结果也只是"已扫完的那些文件"里最靠前的一批，而哪些文件先扫完取决于线程
调度——同一查询两次可能给出不同结果，`<C-q>` 导出的 quickfix 也可能不同。面板用结尾的
`+` 标记这一点：`200/10000+ results`。缩小 pattern(或调大 `g:simplefinder_max_results`，
上限随之提高)就能重新拿到完整扫描和稳定结果集。

`g:simplefinder_include_globs` 和 `g:simplefinder_exclude_globs` 使用相对项目根的
ignore 风格 glob。include 列表非空时只遍历匹配文件，exclude 随后排除匹配项；
例如只查 Rust/TOML 且跳过生成文件：

```vim
let g:simplefinder_include_globs = ['*.rs', '*.toml']
let g:simplefinder_exclude_globs = ['*.generated.rs', 'fixtures/**']
```

过滤在 Rust 遍历层完成，统一作用于 `Files`、`Grep`/`IGrep` 和 `Symbols`，所以
被排除的文件不会再被全文读取。配置会在面板打开时快照，`Resume` 保留该快照；
无效 glob 会成为可见错误。此能力使用协议 v3，旧 daemon 会 fail closed 并提示
重新运行 `./install.sh`，不会静默忽略排除规则。

## 自定义来源

`simplefinder#Pick()` 就是全部扩展面:`:SimpleFinderMarks`、`:SimpleFinderJumps`、
`:SimpleFinderQuickfix` 都是基于它写的,而不是写在它旁边。

```vim
def ColorPicker()
  var items = mapnew(getcompletion('', 'color'), (_, name) => ({display: name}))
  simplefinder#Pick({
    title: 'Colorschemes',
    items: items,
    Accept: (item, _) => execute('colorscheme ' .. item.display),
  })
enddef
```

每一行是一个字典:`display` 是行文本、也是模糊匹配的字段(缺省时回退到 `text`、
`path`)。带上 `path` / `bufnr` / `lnum` / `col` / `text` 这些位置字段,这一行就是
一个"地点":`<CR>` 打开它、预览弹窗显示它、`<C-q>` / `<C-l>` 导出它,全都不需要
任何来源相关的代码。不是地点的来源就自己给 `Accept`。

## 开发与验证

```bash
make check
```

`make check` 是唯一的门禁，CI 也只跑它：`core-verify`(校验 vendored simplecore
的 sha256)、`fmt`、`clippy`、`cargo test`、`defcompile`(强制编译每个 Vim9 def,
否则冷分支里的类型错误要等用户走到才暴露)，以及全部 Vim 端测试。

Vim 与后端通过标准输入/输出上的一行一个 JSON 消息通信。每次查询都有独立 ID；新查询会取消旧任务，过期结果不会写入当前面板。
