# SimpleFinder

SimpleFinder 是一个面向 Vim 9 的轻量、快速项目查找器。Vim9 负责原生侧边面板和交互，Rust 常驻进程负责并行文件扫描、模糊排序和全文检索。

## 特性

- 智能项目根识别，支持手动固定根目录
- 基于 `nucleo-matcher` 的文件名模糊搜索，并行文件扫描，命中字符高亮
- 并行项目全文搜索，支持纯文本、正则、smart-case，匹配片段高亮，跳过二进制文件
- 预览弹窗：实时预览选中文件或匹配行上下文（`<C-e>` 开关）
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
| `:SimpleFinderGrepVisual` | 搜索最近一次可视选择 |
| `:SimpleFinderBuffers` | 查找已打开缓冲区 |
| `:SimpleFinderRecent` | 查找最近文件 |
| `:SimpleFinderLines` | 模糊搜索当前缓冲区的行 |
| `:SimpleFinderHelp` | 模糊搜索帮助标签并打开 `:help` |
| `:SimpleFinderSymbols [query]` | 无需 tags/LSP 搜索项目定义 |
| `:SimpleFinderGitFiles` | 基于 Git 索引查找 tracked/untracked 文件 |
| `:SimpleFinderResume` | 恢复上次搜索（模式、查询、选项） |
| `:SimpleFinderRoot [dir]` | 查看或设置固定搜索根目录 |

推荐自行绑定常用快捷键：

```vim
nnoremap <leader>ff <Cmd>SimpleFinderFiles<CR>
nnoremap <leader>fg <Cmd>SimpleFinderIGrep<CR>
nnoremap <leader>fb <Cmd>SimpleFinderBuffers<CR>
nnoremap <leader>fw <Cmd>SimpleFinderGrepWord<CR>
nnoremap <leader>fr <Cmd>SimpleFinderResume<CR>
xnoremap <leader>fg <Cmd>SimpleFinderGrepVisual<CR>
```

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
| `<C-u>` / `<C-w>` | 清空查询 / 删除上一个词 |
| `<C-r>` | 在全文搜索中切换纯文本/正则 |
| `<C-a>` | 循环大小写模式:smart `[sC]` → 忽略 `[aa]` → 敏感 `[Aa]` |
| `<C-o>` | 切换隐藏文件 |
| `<C-g>` | 切换是否遵循忽略文件 |
| `<C-d>` | 缓冲区模式:关闭选中 buffer |
| `<Esc>` | 关闭面板 |

Location-list export captures both the launching window ID and buffer. If
that split is closed, reused, or separated from the panel into another tab,
SimpleFinder keeps the panel focused and reports the stale target instead of
updating another editing context. Marked entries are always exported in result
order.

## 配置

以下是默认值；请在插件加载前覆盖：

```vim
let g:simplefinder_max_results = 200
let g:simplefinder_debounce_ms = 50
let g:simplefinder_panel_width = 50
let g:simplefinder_position = 'right'       " 'left' 或 'right'
let g:simplefinder_close_on_select = 1
let g:simplefinder_preview = 1              " 默认开启预览弹窗
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

## 开发与验证

```bash
cargo fmt --check
cargo test --locked
cargo build
vim -Nu NONE -i NONE -n -es -S tests/vim_smoke.vim
vim -Nu NONE -i NONE -n -es -S tests/vim_symbols.vim
vim -Nu NONE -i NONE -n -es -S tests/vim_globs.vim
```

Vim 与后端通过标准输入/输出上的一行一个 JSON 消息通信。每次查询都有独立 ID；新查询会取消旧任务，过期结果不会写入当前面板。
