# Changelog

## Unreleased - 2026-08-09

### SimpleRemote virtual workspace 现在可直接使用完整项目查找

- 活动 SimpleRemote workspace 会覆盖本地 root 探测；投影工作区继续使用本地 daemon，
  virtual SSH/Docker 工作区则通过共享传输异步运行 Files、Grep/IGrep、GrepWord、
  GrepVisual、Symbols 和 GitFiles，不要求远端额外安装 simplefinder-daemon。
- 远端文件列表只跨连接枚举一次，查询继续在本地模糊过滤；全文搜索支持取消和增量渲染。
  `rg` 可用时 hidden、ignore 和 include/exclude glob 保持一致，缺少时降级到
  Git/find/grep。
- 远端结果可以 edit/split/vsplit/tabedit、导出 quickfix/location list；预览通过新增的
  SimpleRemote 异步读 API 获取，已打开且修改过的 remote buffer 仍优先使用内存内容。
- SimpleRemote 的 connected/workspace-changed/disconnected 事件会令活动面板停止旧请求并
  跟随新根；远端会话中的 `:SimpleFinderRoot` 会反向切换真实远端 workspace。
- 新增 `g:simplefinder_remote`（默认 1）作为总开关，并加入 virtual Files/Grep/Symbols/
  GitFiles、预览、打开和换根的端到端回归测试。

### 另外三个会 clamp 的下限，也不再被报成 `[ERROR]`

- 上一条把 `history_max`、`preview_width`、`preview_max_bytes` 降级成了 `[WARN]`，可
  同一张表里 `lines_max`、`recent_files_max`、`debounce_ms` 三个的下限依旧没有
  `min_note`，于是照样报 `[ERROR]`——而这三个值插件同样在用：`lines_max = 0` 时
  `if len(s_all_lines) >= mx` 是在 add 完一行之后才判断的，结果跟 1 完全一样；
  `recent_files_max = 0` 走的是 `combined[: -1]`，Vim 的切片里 -1 指最后一个元素，整
  张表原样留下；`debounce_ms = -1` 交给 `timer_start()` 也照样得到一个有效的 timer 并
  如期触发。三个都补上 `min_note`，降级为 `[WARN]` 并说明插件实际会怎么做。
- 两处"用得上但不是你写的那样"顺带钉死，免得报告讲的是巧合：`recent_files_max` 低于
  下限时不再依赖切片的偶然——`combined[: mx - 1]` 在 -1 时是 `[: -2]`，每访问一个文件
  就悄悄丢掉一条，读列表时再丢一条——现在明确地不裁剪；`debounce_ms` 低于下限时 clamp
  到 0，不再指望 `timer_start()` 对"已经过去的到期时间"的未文档化的宽容。
- `max_results` 是唯一仍报 `[ERROR]` 的下限，这不是漏网：空查询是从列表头部取 `max`
  条，0 条就是什么都不列，这个值确实用不上。

### health 报告不再霸占一个同名文件的 buffer

- 报告一直是用名字打开的：`:split SimpleFinderHealth`。可这条命令绑定的是那个**文件
  名**，于是在一个碰巧有 `SimpleFinderHealth` 这个文件的目录里，`:SimpleFinderHealth`
  接管的是正在编辑它的那个 buffer——内容被清空，`buftype` 被按成 `nofile`（于是再也写
  不回磁盘），`modified` 被清掉，未保存的修改就这么无声无息地没了，连一句警告都没有。
  磁盘上的文件没被覆盖（`:w!` 会以 E382 拒绝），但这一个会话里的改动是真丢了。
- 现在报告先用 `bufadd('')` 建一个全新的空 buffer——空名字每次都建新的，撞不到任何
  东西——设好 `nofile` 之后再命名成 `SimpleFinderHealth`。名字已经被别的 buffer 占着
  时 `:file` 会报 E95，那就不要这个名字：一份不带名字的报告读起来一模一样，而别人的
  buffer 一个字都不该动。
- `tests/vim_health.vim` 新增一段：在一个放着 `SimpleFinderHealth` 文件的目录里打开
  它、改一行不存盘，再跑 `:SimpleFinderHealth`——报告必须落在另一个 buffer 上，原来那
  个的内容、`buftype` 和 `modified` 必须原封不动。这段必须跑在最前面，因为出事的是
  "第一次创建"那条路。

### 三个插件其实会 clamp 的下限，不再被报成 `[ERROR]`

- `[ERROR]` 的含义是"这个值根本用不上"，而且只有 `[ERROR]` 会在一次会话第一次搜索前
  用 WarningMsg echo 出来；"低于插件自己会 clamp 的下限"按文档是 `[WARN]`。可
  `history_max`、`preview_width`、`preview_max_bytes` 三个的下限都没写 `min_note`，于
  是被报成了 `[ERROR]`——`max([0, ...])`、`if wanted > 0`、`max_bytes > 0 &&`，三处代码
  对低于下限的值的处理跟 0 完全一样。写 `let g:simplefinder_preview_max_bytes = -1`
  表示"不限大小"的人，因此每个会话都会在第一次搜索前挨一条红色的错误，而插件正按他
  想要的方式在跑。同一张表里 `threads = -1` 形状完全相同却是 `[WARN]`，差别只在它带了
  `min_note`。
- 三个都补上 `min_note`，降级为 `[WARN]`，并说明插件实际做了什么；帮助里那份下限清单
  也一并写清楚：带括号说明的那些就是 `[WARN]`。

### `g:simplefinder_grep_cache = 0` 真的变回不遍历列表

- 这个开关的承诺是"回到 0.5.0 之前那样每次都走遍历"，可 `grep_by_walk()` 无论如何都
  会把走到的每个路径丢进 mpsc channel、收成 `Vec<String>` 再排序，而 `serve()` 在关掉
  开关时把整份列表直接丢掉。结果是这条"省事"的路比它要恢复的旧行为**更贵**：10 万文件
  的仓库里，每一次真正打到 daemon 的按键都要多分配 10 万个 String 并排一次序。老插件
  不发这个字段，走的也是同一条路。
- `file_cache` 现在进了 `GrepOptions`：没要列表就不建 channel、不收集、不排序，直接
  返回 `None`。`serve()` 那边的 `&& use_file_cache` 也就成了多余，去掉。
- 新增 `a_grep_that_opted_out_of_the_cache_builds_no_list`：关掉开关的 grep 结果不变，
  但不许带回列表。

### `:SimpleFinderHealth` 变成真的诊断，配置会被校验一次

- 全新会话里打开 health，头两行是 `[ERROR] daemon` 和 `[ERROR] state: not running`
  ——两句都是真的，也都毫无意义：daemon 本来就随第一次搜索启动。用户唯一会在"出问题
  了"时跑的那条命令，第一眼给的是一条假线索，引用它的 bug report 全都走进死胡同。
  与此同时，真正会发生的两种故障它一句都没说：插件管理器升级后留在 `lib/` 里的旧
  二进制，和写错的 `g:` 选项——后者是纯粹的沉默，因为每个读取点都是
  `get(g:, ..., 默认值)`，名字错了就永远读不到。
- 现在报告写进一个 scratch buffer（可读、可滚、可粘进 issue），固定五段：
  `ENVIRONMENT` / `BINARY` / `CONFIG` / `RUNTIME` / `CONTEXT`，顺序固定且永远都在，
  两份报告能并排看，少一条事实读起来就是少一条事实。`RUNTIME` 在 daemon 从未启动过
  时只说一句 `not started yet`，级别是 `[INFO]`。
- `BINARY` 会比对二进制与 `src/**/*.rs` 的 mtime，并把 `--version` 的结果对上
  `Cargo.toml` 里的版本——升级只换了 Vim 文件、没重跑 `./install.sh` 的那种破法，只有
  这里看得出来。版本用 `job_start()` 异步问：这条命令正是因为二进制卡住才跑的，
  `system()` 会把命令本身一起挂死。第一份报告写 `probing…`，答案到了就地重画。
- 版本探测带 3 秒期限。异步本身还不够：真正卡死的二进制正是 `job_start()` 看不见的
  那一种——它成功返回，子进程就那么杵着，`exit_cb` 永远不来，于是这行会 `probing…`
  一整个会话，那个因为二进制卡住才跑这条命令的人一条事实都拿不到，和当初的
  `[ERROR] daemon` 一样是死胡同。现在到点就停掉子进程，这行写成
  `[ERROR] version: the binary did not answer --version within 3s`，同样就地重画
  （健康的 `--version` 只要几毫秒，3 秒是任何能用的二进制都不会错过的期限）。
  超时之后再跑一次 `:SimpleFinderHealth` 会重试一次——只有显式命令重试，就地重画不
  重试，否则报告开着的时候会每 3 秒重探一次。换二进制时还在飞的那次探测会被一并停掉。
- 新增 `simplefinder#ValidateConfig()`：选项全集声明在一张表里，校验类型、取值集合、
  数值下限、列表元素、glob 的 `!` 前缀、`root` 是不是目录、`daemon_path` 能不能执行、
  `ignore_case` 与 `smart_case` 撞车，以及任何不在表里的 `g:simplefinder_` 名字。
  下限取的是插件自己 clamp 的那个数（`panel_width` 是 24，不是随手写的数字），否则
  报告会在描述一个插件根本不会打开的宽度。`[ERROR]` 表示这个值用不上，`[WARN]` 表示
  会用、但不是按你写的用。`g:loaded_simplefinder` 和裸的 `g:simplefinder` 不归我们管。
- 同一份列表就是 health 的 `CONFIG` 段；其中 `[ERROR]` 另外在一次会话的第一个面板
  打开后 echo 一次（在 `PanelRender()` 之后，否则消息会被面板盖掉），`[WARN]` 只留在
  报告里——搜索不是挨训的地方。
- 新增 `tests/vim_health.vim`：默认配置必须是干净的；全新会话的 `RUNTIME` 只有一条且
  不能带 `ERROR`；版本探测必须从 `probing…` 收敛到 `[OK] version: x.y.z`；daemon 起来
  之后必须报 running；每一类配置错误都要被点名并带上导致它的那个值；拼错的选项必须在
  第一次搜索时被说出来，而且只说一次；对着一个 `sleep 600` 的假 daemon，报告必须自己
  从 `probing…` 走到那条超时的 `[ERROR]`（读的是 buffer，所以就地重画也一并被验），
  再跑一次命令必须重新回到 `probing…`。

### 预览弹窗不再画到没有面板的那个 tab 上

- `PanelRender()` 改成 tabpage 无关是对的(面板待在另一个 tab 时也该收结果),
  但预览被一起带了过去,而 popup 恰恰是 tabpage 局部的:`popup_create()` 建在
  **当前** tab,而它的几何来自 `win_screenpos(win_id2win(面板))`——跨 tab 时
  `win_id2win()` 返回 0,`win_screenpos(0)` 是"当前窗口"。于是在另一个 tab 里
  编辑时到达的一批流式结果,会把一个 grep 结果的预览浮在你正在看的 buffer 上,
  尺寸还是照着错误的窗口算的;弹窗已经存在时则被挪到一个错误的列,切回去才发现
  位置不对。
- 现在面板不在当前 tab 就不画预览(面板本身照常重绘),几何直接取
  `getwininfo(面板)[0].wincol`,切回面板时预览重新出现。
- 新增 `tests/vim_tabs.vim`:面板留在 tab 1、光标在 tab 2 的分屏里时放行一批
  流式结果——面板 buffer 必须拿到结果,而 tab 2 里必须一个弹窗都没有;切回去
  之后预览回来,且宽度必须是按面板窗口算出来的。

### `:SimpleFinderStop` 不会被一个还在等握手的搜索复活

- 握手未完成时挂起的请求由一个 2 秒定时器兜底,但没有任何东西会取消它,而重新
  派发要经过 `EnsureBackend()`——那是**启动** daemon 的那条路。结果是:搜索挂起
  期间执行 `:SimpleFinderStop`,2 秒后进程又被拉起来,屏幕上没有任何东西解释它
  从哪来。文档里"显式停止不会被在途事件撤销"的承诺,在这条路径上没有兑现。
- `Stop()` 现在取消挂起的握手等待(停表、丢弃挂起的请求),面板不再停在
  `searching…`,而是说明放弃的原因;`FinishNegotiation()` 另外加一道保险,
  daemon 已经不在了就不再派发。`:SimpleFinderRestart` 不受影响——那里的请求
  本来就该等新进程握手。
- 新增 `tests/vim_negotiate.vim` 与 `tests/fake_slow_daemon.py`(拿不到 gate
  文件就永远不回 ping):停止之后跨过 2 秒预算,daemon 必须仍然是停的,而且
  假 daemon 记录的进程数必须还是 1;随后用户自己再搜一次仍然能正常启动、协商、
  出结果。

### marks 的文件名不再经过 `expand()`

- `Marks()` 用 `fnamemodify(expand(file), ':p')` 解析标记所在的文件,而
  `expand()` 是通配符/环境变量/`%`、`#` 特殊符/反引号展开器:在
  `lit$HOME.txt` 里设的标记被列成、预览成、导出成 `lit/home/you.txt`——一个不
  存在的路径。同一轮里预览已经把这个缺陷去掉了,marks 漏了。
- 改用 `fnamemodify(file, ':p')`,`~` 与相对路径照常解析。
- `tests/vim_pick.vim` 覆盖:在带 `$` 的文件名里设一个全局标记,面板必须按真实
  文件名列出它。
- `tests/vim_preview.vim` 里那条"名字里带 `#`/`%`"的断言是**不可能失败**的:
  `expand()` 只在命令行上把 `%`/`#` 当文件特殊符,字符串中间不展开,所以它在
  改动前的代码上照样通过;而且用 `lines` 来源时条目自带 buffer 号,预览根本不
  走路径。改成用带 `$` 的名字、并且从磁盘(而非 buffer)预览,这才真正覆盖。

### 全文搜索不再为每次按键重新遍历目录树

- 交互式 grep 每敲一个字符发一个请求,而每个请求此前都要把整棵树重新走一遍:
  每个 `.gitignore` 重新读、每个目录重新 stat,然后才轮到读第一个文件。daemon
  本来就为 `:SimpleFinderFiles` 保留着这份列表(key 里已经含 root、hidden /
  no_ignore 和路径 glob),现在过滤条件相同的 grep 直接读它;确实需要遍历的
  grep 则把自己走出来的列表发布回去,下一次按键就不用再走。
- 被取消或被扫描上限截断的遍历**不**发布列表:半棵树一旦被当成整棵树缓存,
  之后每次搜索都会对剩下的部分视而不见。
- 列表最多 30 秒(与文件查找一致),所以面板开着时新建的文件要等它过期才会被
  搜到。新增 `g:simplefinder_grep_cache`(默认 1,置 0 恢复每次遍历)。
- 走 capability 协商(`grep_cache`),请求字段 `file_cache` 默认关闭:旧 daemon
  收不到这个字段,也不会被误以为已经在复用列表。符号搜索同样受益,它就是一次
  全项目 grep。
- Rust 侧把"走树"和"读列表"两种取候选文件的方式拆开,单文件内的搜索、排序、
  扫描上限和流式批次这些逻辑只写一份(`GrepScan`),两条路径不会各自漂移。
- 新增测试:遍历产生的列表必须与 `get_or_walk_files` 的完全一致(否则缓存的就
  不是同一棵树);给定列表时列表外的文件绝不被搜索;被截断的遍历不发布列表;
  新增 `tests/vim_cache.vim` 与 `tests/fake_echo_daemon.py`,直接对**请求**断言
  协商结果——能力齐备时 `file_cache` 为真、用户关闭时为假、旧 daemon 下为假。

### 模糊打分并行化,线程数可配

- `fuzzy_filter` 此前在单线程里给整份文件列表打分,而这是**每次按键**都要做的事:
  10 万文件的仓库里一个核在算、其余核在等。打分是逐候选独立的,现在按线程切块、
  每线程一个 matcher,合并后再做那一次决定顺序的排序——排序带 path 兜底比较,
  所以合并顺序不会泄漏进排名,结果与单线程逐字节一致。
- 遍历与打分此前都写死 `num_cpus().min(8)`。新增 `g:simplefinder_threads`
  (请求里的 `threads` 字段,默认 0 = 每核一个,daemon 侧 clamp 到 1..64)。
  旧 daemon 会忽略这个字段,旧插件不发这个字段,两个方向都落在默认值上。
- 新增 Rust 测试:同一份 14000 条候选列表,1/2/4/13 线程必须给出完全相同的
  存活集合、顺序、总数与高亮位置;以及线程数 clamp 的边界。

### 公开的 picker API、`<Plug>` 目标,以及基于它们的新来源

- 新增 `simplefinder#Pick({spec})`:传一份行列表就能打开面板。这是唯一的扩展面,
  `spec` 支持 `items` / `title` / `key` / `Accept`。每一行是一个字典,`display`
  是行文本兼模糊匹配字段(缺省回退 `text`、`path`);带上 `path` / `bufnr` /
  `lnum` / `col` / `text` 就是一个"地点",`<CR>` 打开、预览显示、`<C-q>` / `<C-l>`
  导出全部照常工作,不需要任何来源相关代码。多选身份、`:SimpleFinderResume`
  也一并适用。
- 新增三个内建来源,而且是**基于**这套 API 写的(不是写在旁边,所以 API 烂了
  它们会一起烂):`:SimpleFinderMarks`(当前 buffer 的 a-z 在前,再是 A-Z / 0-9,
  跳过 `'.` `'^` `'"` `'<` `'>` 这些没人设过的自动标记)、`:SimpleFinderJumps`
  (跳转表,最近的在前)、`:SimpleFinderQuickfix` / `:SimpleFinderLoclist`
  (在一个 400 条的 quickfix 列表里模糊查找,正是 `:cnext` 最不擅长的事)。
- 每个命令都补上了 `<Plug>` 目标(`<Plug>(simplefinder-files)` 等 15 个,加上
  原有的 `-grep-visual`),文档改为推荐绑定 `<Plug>` 而不是命令名:命令以后要加
  参数或包一层,别人 vimrc 里的映射不会因此断掉。
- 新增 `tests/vim_pick.vim`:`<Plug>` 目标齐全、`Pick()` 的窄化与 `Accept` 回调、
  没有 `Accept` 时按位置跳转、`display` 的两级回退、坏 spec 只报错不抛异常,以及
  marks / jumps / quickfix / loclist 四个来源的行内容与跳转。

### 预览弹窗:语法高亮、滚动、读 buffer、带缓存

- 预览此前每次移动光标都 `readfile(path, '', start + height - 1)`,而这是从
  文件头一路读到目标行:一个在 40000 行文件里靠后的结果,每按一次 `<C-j>` 就
  重读几万行,在同一个文件的两个结果之间来回还要各付一次。现在整文件读一次再
  切片,并按 (路径, mtime, 大小) 缓存最近 `g:simplefinder_preview_cache`(默认
  4)个文件。
- 文件已经在某个 buffer 里打开时,预览直接读 buffer:`lines` 模式的条目文本本来
  就来自 `getline()`,此前预览却读磁盘——插入五行未保存的内容之后,高亮的那一行
  根本不含匹配。buffer 在内存里,因此不受 `g:simplefinder_preview_max_bytes`
  (默认 2 MiB,取代写死的常量)限制。
- 预览按 filetype 高亮:已加载 buffer 用它自己的 `&filetype`,否则按扩展名查表
  (`g:simplefinder_preview_syntax = 0` 关闭)。仅在 filetype 变化时才重设,避免
  每次移动光标都重新加载语法文件。
- `<PageDown>` / `<PageUp>` 滚动预览。滚动相对当前匹配,换一个结果就复位。
- 新增 `g:simplefinder_preview_width`(默认 0 = 用满面板旁边的列)。
- 路径不再经过 `expand()`:那是个对着文件名跑的通配符/环境变量/`%`、`#` 展开器,
  文件名不是表达式。改用 `fnamemodify(':p')`,只做 `~` 和相对路径解析。
- 新增 `tests/vim_preview.vim`:未保存 buffer 的内容、按 filetype 的高亮(已打开
  与未打开两种来源)、滚动与到底停住、换结果复位、名字里带 `$`/`#`/`%` 的文件。

### 查询变成真正可编辑的提示行

- 此前查询只能往末尾追加:长模式中间打错一个字,就得把后面全删掉重打。现在
  提示行里的方块是**查询光标**,`<Left>`/`<Right>`/`<Home>`/`<End>` 在查询里
  移动,插入、`<BS>`、`<C-w>` 都发生在光标处(`<C-w>` 只吃光标前的那个词)。
  光标按字符计,多字节查询不会被从中间切开。
- 新增 `<C-y>{reg}`:把寄存器粘到光标处。面板收键是每个可打印 ASCII 字符一条
  映射,CJK 标识符**打不进去但可以粘进去**;多行寄存器按空格拼成一行,行尾换行
  丢弃,寄存器名按 `<Esc>` 取消则什么都不改。
- 新增按来源分开的查询历史:`<C-Up>` 往回、`<C-Down>` 往前,走过最新一条会还原
  开始回溯时正在编辑的那条。grep 与 igrep 共用一份(本来就是同一种搜索),其余
  来源各自一份——文件路径片段和 grep 模式互相翻出来只会碍事。历史只存在于当前
  Vim 进程里,不落盘。`g:simplefinder_history_max` 默认 50。
- `g:simplefinder_lines_max`(`:SimpleFinderLines` 的行数上限,默认 50000)此前
  代码里在读、却既没在 `plugin/` 里声明也没在任何文档里出现,一并补上。
- 新增 `tests/vim_prompt.vim`:光标插入/删除、`<C-w>` 的两种边界、寄存器粘贴
  (含中文与多行寄存器)、历史的回溯/前进/去重/按来源隔离,全部跑在纯 Vim 的
  `lines` 与 `help` 来源上,不涉及 daemon。

### 会话里的第一次搜索也会流式返回

- `EnsureBackend()` 只负责**启动**进程:ping 还在路上、pong 没回来,
  `HasCap('stream')` 自然是 false,于是请求带着 `stream: false` 发出去——偏偏
  这一次搜索是最慢的一次(什么缓存都还没有)。而 `:SimpleFinderGrep`、
  `:SimpleFinderGrepWord`、`:SimpleFinderGrepVisual` 都是一次性命令,之后没有
  任何东西会重发,所以帮助里承诺的流式在会话的第一次搜索上从来没兑现过;
  `:SimpleFinderRestart` 之后、崩溃重启之后同样如此。
- 握手未完成时发起的搜索现在挂起等待 pong,拿到能力后再按面板的当前状态重新
  派发(mode/query 都从面板读,期间关掉面板就不再发)。等待有 2 秒上限:一个
  永远不回应握手的 daemon 仍然会收到请求,只是退回旧的单次应答行为。
- `:SimpleFinderSymbols` 也带上 `stream` 字段——它本来就是一次全项目 grep。
- `tests/vim_stream.vim`:会话的第一条 grep 命令(daemon 尚未启动)必须逐批
  上屏。此前那条 "未协商的请求只应答一次" 的断言用的 pattern 根本没有批次
  序列,假 daemon 无论 `stream` 是 true 还是 false 都只回一次,是一个**不可能
  失败的测试**。改由 `FAKE_NO_STREAM` 让假 daemon 不声明 `stream` 能力,真正
  覆盖旧 daemon 的降级路径。

### `<C-f>`:在命令行上编辑查询

- 面板用 `<Char-32>`..`<Char-126>` 逐个字符建映射来收键,也就是只覆盖可打印
  ASCII。非 ASCII 键没有任何映射,落进一个 nomodifiable 的 nofile buffer 后被
  静默吞掉——在一个 README 就是中文的插件里,从面板 grep 中文标识符根本做不到。
- 新增 `<C-f>`:把当前查询交给 Vim 命令行编辑一次,回车后按结果重新搜索。
  由此一并解决三件事:非 ASCII 输入、在查询中间移动光标、用 `<C-r>` 粘贴寄存器。
- `<Esc>` 取消编辑保持原查询不变(清空查询仍然用面板的 `<C-u>`)。
- `tests/vim_grep.vim` 覆盖:`<C-f>` 输入中文必须出现在查询行。

### 面板在另一个 tab 时也会绘制结果

- `PanelRender()` / `SyncCursorLine()` 用 `win_id2win()` 做存活判定,而它是
  tabpage 局部的:面板好端端地待在另一个 tab 时它返回 0,于是异步到达的结果
  只写进状态、从不落到 buffer——切回去看到的是一个停在 `searching…` 的面板,
  要按一下键才会更新。改用 tabpage 无关的 `getwininfo()`;渲染本身走
  `setbufline()`,`win_execute()` 也能跨 tab,没有任何需要跳过的理由。
- `tests/vim_grep.vim` 覆盖:发起搜索后立刻 `tabnew`,面板 buffer 仍须拿到结果。

### 未命名缓冲区也能导出到 quickfix

- `<C-q>` / `<C-l>` 现在优先使用结果自带的 `bufnr`。此前条目只带 `filename`,
  未命名缓冲区的 `filename` 是空串,`setqflist()` 会生成 `bufnr: 0` 的条目,
  `:cc` 和列表里的 `<CR>` 都跳不到任何地方。`AcceptItem()` 早就是这么解析的。
- 冒烟测试覆盖:`:enew` 后 `:SimpleFinderLines` 再 `<C-q>`,导出的条目必须带
  真实 bufnr 且 `valid`。

### CI 以 Makefile 为唯一事实来源

- `test` job 改为只跑 `make check`。此前它手抄了 Makefile 的一部分:clippy 从未
  在 CI 里跑过,而几个 Vim 测试排在"安装 Vim"这一步之前。
- MSRV job 的工具链版本改为从 `Cargo.toml` 的 `rust-version` 读取,不再手写。
  本套件里有六个仓库把 pin 写成 1.85.0 而 `Cargo.toml` 声明 1.88,`cargo check
  --locked` 对更高的 rust-version 是硬错误,于是每次 push 都红——注释要求"保持
  同步"并不是一道检查。

### grep 结果流式返回

- 协议里的 `done` 字段从第一版起就存在,却从来没有被置为 false:每个请求只产生
  一个事件,所以在大仓库冷启动时面板会一直显示 `searching…` 和空结果区,直到最后
  一个文件读完。现在 grep 边遍历边分批返回,标题显示 `12 results · searching…`。
- 每批是**完整有序的快照**而不是追加。有界堆可能把后发现的匹配插到已显示行的
  前面,追加会让行序在结束时突然重排;快照只会逐步收敛。因此丢掉一批也无害,
  中间批次用非阻塞发送,只有最终 `done: true` 那批带背压。
- 光标按结果的稳定身份跟随,而不是按下标:新匹配插到光标上方时,光标仍停在原来
  那一行。只有 `done: true` 才结束 loading 并给出权威的 total/capped/耗时。
- 视口同样保持不动:此前每批只恢复光标下标却把滚动偏移清零,选中项虽然没变,
  整个面板却会跳回顶部——真实遍历每 80ms 一批,读结果时会被反复拽走。现在锚点
  行在视口中的相对位置一并恢复。
- 协议升到 v4 并声明 `stream` capability。请求里新增 `stream` 字段,只有握手确认
  支持后才置位,所以旧 daemon 与旧插件的组合都保持单次应答。
- `:SimpleFinderFiles` 不流式:模糊排序需要完整文件列表才能定序。
- 新增 Rust 回归测试(遍历结束前必须已经发出有序批次)与 `tests/vim_stream.vim`
  (用可控的假 daemon 逐批放行,断言部分状态文案、光标锚定与最终计数)。

### 截断的 grep 结果变得确定且诚实

- 超出 `g:simplefinder_max_results` 的 grep 现在保留 (path, lnum, col) 排序中
  最靠前的一批。此前 worker 线程按遍历完成顺序追加到共享 Vec,而 drain 是先
  截断再排序,同一查询两次会返回两个不同的子集,`<C-q>` 导出的 quickfix 也随
  线程调度变化——"grep 之后修完 quickfix 里所有匹配"的工作流会静默漏掉匹配。
- daemon 改用按 (path, lnum, col) 定序的有界堆加 `AtomicUsize` 计数,内存不再
  随命中数增长,并回报真实总数:面板显示 `200/5312 results`,不再是无从证伪的
  `200+ results`。
- 为了不让 `.` 这类正则拖垮整棵树,统计有上限(`max` 的 50 倍,至少 10000)。
  触顶会结束遍历本身,所以确定性只在完整扫描的前提下成立:触顶后总数是下界,
  结果集也只是"已扫完的那些文件"里最靠前的一批,取决于线程调度,同一查询两次
  可能不同,`<C-q>` 导出的 quickfix 也可能不同。面板结尾的 `+` 正是这个意思
  (`200/10000+ results`);缩小 pattern 或调大 `g:simplefinder_max_results`
  (上限随之提高)即可恢复完整扫描。
- 新增 Rust 回归测试(同一截断查询多次运行必须字节一致)与
  `tests/vim_grep.vim`(`<C-q>` 导出的 quickfix 必须每次相同)。

### 可视模式 grep 搜的是当前选区

- `:SimpleFinderGrepVisual` 在可视模式下改读 `v` / `.` 的实时选区。此前它读
  `'<` / `'>` 标记,而 `<Cmd>` 映射运行时选区尚未结束、标记仍指向上一次选区,
  所以每次都搜错文本;一个会话里的第一次选区更是什么都搜不到。
- 字符选区、行选区(`V`)、块选区(`<C-v>`)现在都正确,多行以空格连接;选区
  末尾的多字节字符不再被从中间截断。
- 新增 `<Plug>(simplefinder-grep-visual)`,README 与帮助文档改为推荐它;
  `:'<,'>SimpleFinderGrepVisual` 没有活动选区可读,继续按标记工作。
- 新增 `tests/vim_visual.vim` 回归测试:连续两次不同选区必须搜到第二次。

### 跨筛选稳定多选

- `<Tab>` / `<S-Tab>` 标记现在绑定完整结果身份,不再绑定易随查询和异步响应变化
  的屏幕下标；结果重排不会把标记悄悄转移到另一文件或匹配行。
- 被后续查询隐藏的已标记项保留完整快照,`<C-q>` / `<C-l>` 仍按首次标记顺序
  导出；取消标记释放单项快照,关闭面板释放全部选择,Resume 不复活隐形旧标记。
- 回归测试覆盖标记后缩窄查询、隐藏项导出顺序及新面板生命周期。

### Split-local 结果工作流

- 面板新增 `<C-l>`:将标记结果(无标记时为全部)按原结果顺序导出到启动 split
  自己的 location list;`<C-q>` quickfix 行为保持不变。
- 打开面板时同时捕获稳定 winid 与 bufnr。若源 split 已关闭、换了 buffer,或
  panel 被移到另一个 tab,导出会 fail closed、保持面板焦点并显示错误,不会把
  结果悄悄写到复用后的错误上下文。
- Vim 冒烟测试覆盖 marked-only 顺序、location list 归属以及源 window/buffer
  失效边界。

### 原生路径过滤

- 新增 `g:simplefinder_include_globs` / `g:simplefinder_exclude_globs`。
  两组 ignore 风格 glob 由 Rust walker 原生执行,统一作用于文件查找、普通/实时
  grep 与符号搜索;被排除的文件不会再被打开做全文扫描。面板标题显示 include /
  exclude 数量,`:SimpleFinderResume` 保留打开面板时的过滤快照。
- 文件缓存 key 纳入完整 glob 配置,切换过滤器不会误复用另一组路径列表;grep 与
  files 共用同一套 matcher 构建和错误语义。最多 256 条、单条最多 4096 字节,
  空值、前导 `!` 与非法语法都会返回明确错误。
- 协议升到 v3 并声明 `path_globs` capability。新 Vim 端遇到旧 daemon 时 fail
  closed 并提示重跑 `./install.sh`,不会静默搜索用户明确排除的路径。
- 新增 Rust 回归测试与 `tests/vim_globs.vim` 端到端测试,覆盖 include + exclude
  组合在 files/grep/symbols 三条路径的一致性、错误配置与非法 glob;CI 同步验证
  v3 握手、capability 和声明的 Rust 1.88 MSRV。

### 全套统一

- `.simplecore/` 回来了。10 个仓库里的 supervisor(`autoload/<plugin>/core.vim`
  与三个测试文件)本来就是一套 vendored bundle,但源头目录早已丢失,而每个
  Makefile 都还在引用 `../.simplecore/vendor.sh`。现在 bundle 有了源头,而且
  每个仓库带一份 `.simplecore.manifest` 记录各文件的 sha256,`make core-verify`
  会校验它,`check` 依赖它——手改 vendored 文件会在改它的那个仓库里直接失败,
  不需要 `.simplecore/` 在场。
- 安装器抽成共享的 `install-common.sh`,各仓库的 `install.sh` 只剩配置。
  由此补齐的能力:构建前检查 cargo/rustc 与 MSRV(此前 3 个仓库缺,用户看到的
  是一屏 trait 解析错误);原子替换(此前 2 个仓库是就地覆写,Vim 还开着旧 daemon
  时会 ETXTBSY);Windows 的 `.exe` 后缀;安装前用 `--self-test` 验证刚构建的
  二进制;以及生成 helptags。
- `make check` 现在是每个仓库统一的完整门禁。simplemarkdown 与 simpleminimap
  此前叫 `make test`,旧名字保留为别名。
- daemon 的命令行统一为 `--version` / `--help` / `--self-test`。

### 工具链

- `rust-version` 统一到 1.88(此前 1.85 与 1.88 各半)。实测:1.88 能构建全部
  10 个仓库,1.85 只能构建 5 个。
- `cargo update`:全部为补丁级更新。

  注意:这次更新让 `ignore` 从 0.4.27 升到 0.4.30+,而后者用了 let-chains。
  simplefinder 与 simpletree 此前声明的 1.85 在更新前是真实可用的,更新后不再成立
  ——这是这次依赖刷新付出的代价,不是发现了旧的错误声明。
- MSRV 提到 1.88 后,clippy 的 `collapsible_if` 开始建议用 let-chains 合并
  (该 lint 受 MSRV 门控)。已按建议合并,语义不变。

### 本插件

- `--version`/`--help`/`--self-test`:此前 daemon 完全忽略命令行参数。
- `ignore` 升到 0.4.33。此前被 MSRV 卡在旧版本上。

### 新增:符号搜索

- `:SimpleFinderSymbols [query]`:在整个项目里搜定义(fn / struct / def / class /
  func / interface …),按当前 buffer 的文件类型选关键字集合,再用 query 收窄,
  边打边筛。
- 背后没有 tags 文件、也没有语言服务器,用的就是 daemon 已有的 grep:不需要任何
  配置,不会与磁盘上的文件脱节,大仓库里几毫秒出结果。代价是它比真正的索引粗——
  它告诉你名字在哪里被定义,而不是它解析到什么。
- `g:simplefinder_symbol_keywords` 可按文件类型覆盖关键字集合;
  `g:simplefinder_symbol_all_languages` 一次搜所有语言(多语言仓库通常要的就是这个)。
- `:SimpleFinderResume` 支持恢复该来源。
- 新增 `tests/vim_symbols.vim`。其中两条是针对开发中真实踩到的坑:
  关键字集合必须取自**源 buffer** 的 filetype(在面板打开之后再读 `&filetype`
  会读到面板自己的 buffer,于是静默退化成"搜所有语言",Rust 文件因此匹配到了
  `let`);以及用户输入里的正则元字符必须转义(`needle(`、`[unclosed` 会直接让
  pattern 报错)。去掉任一处修复,测试都会失败。

### 修复:daemon 文件缓存无界增长

- daemon 的文件缓存以 root 为键缓存整份文件路径列表,30 秒的 TTL 只决定条目
  "能不能用",从不负责把它删掉。daemon 活在整个会话期间,于是每搜过一个项目就
  永久留下它的完整路径表(每个 root 还因 hidden / no_ignore 组合占 4 个键),
  长时间跨多个仓库工作会持续吃内存。
- 现在插入时顺带清理:过期条目直接丢弃,并以 `CACHE_MAX_ROOTS`(16)为上界淘汰
  最旧的条目。清理在已持有写锁、且刚刚遍历完整棵目录树的路径上完成,开销可忽略。
- 新增两个 Rust 回归测试:过期条目必须被删除、缓存必须有界且淘汰最旧的。

### 构建与 CI 修复

- `ignore` 锁定回 0.4.27:0.4.30 使用了 let-chains(需要 Rust 1.88),而本 crate 声明 MSRV 为 1.85,按声明版本无法编译。新增 CI 的 MSRV 作业防止再次漂移。

### 新增

- `:SimpleFinderGitFiles`:在当前 git 仓库内模糊查找文件。用 `git ls-files` 读
  索引而不是遍历目录树,超大仓库下依然很快,并且天然遵守 .gitignore、sparse
  checkout 与 skip-worktree;同时包含未被忽略的未跟踪文件,刚新建的文件不必先
  `git add` 就能找到。路径以仓库根为基准解析(可能与 `:SimpleFinderRoot` 不同)。
  `:SimpleFinderResume` 支持恢复该来源。

### 修复

- `EnsureBackend()` 用 `s_job != v:null` 判定启动成功,而 `job_start()` 在
  exec 失败时同样返回 job 对象:一旦 daemon 起不来,插件会在整个会话里都认为
  它在运行,每次搜索都往死掉的管道里写。
- 没有代际守卫:停止后紧接着启动时,旧 job 的 `exit_cb` 会把新 job 的状态清空。
- daemon 中途退出时面板会一直转圈;现在会给出明确错误,自动重启期间提示重启中。

### 新增

- 协议握手(协议版本 2):daemon 新增 `ping` 请求,回复 `pong` 并带上版本号与
  能力集合;`:SimpleFinderHealth` 会显示协商结果,旧 daemon 会被明确提示重装。

### 可靠性:统一 daemon 监督层 (simplecore)

- 进程生命周期改由 vendored `simplecore` 监督层接管(`autoload/simplefinder/core.vim`,
  从 `.simplecore/` 同步,请勿直接编辑)。九个插件共用同一份实现:
  - 存活判定一律走 `job_status()`。`job_start()` 即使 exec 失败也会返回 job
    对象,所以 `job != null` 并不能说明进程还活着。
  - 代际守卫:被替换掉的旧 daemon 的 `exit_cb` 迟到时,不会再清掉接替它的新
    进程的状态。
  - 停止栅栏:显式停止后仍在管道里的事件会被丢弃,不会把刚拆掉的状态又写回去。
  - 指数退避自动重启;同一时间窗内反复崩溃则熔断,只报错一次而不是无限重启。
    手动 `:SimpleFinderRestart` 会重新合闸。
  - 请求按 id 关联并支持超时,卡死的 daemon 不会让回调永远悬着。
- 新增 `:SimpleFinderHealth`、`:SimpleFinderRestart`、`:SimpleFinderLog`,全套插件命名一致。

### 测试

- 新增 `tests/vim_core.vim`:监督层回归套件(存活判定、代际守卫、停止栅栏、
  退避重启、崩溃熔断、请求超时、协议握手、raw/json 两种编解码),由
  `tests/fake_daemon.py` 驱动——一个可以按需应答/静默/乱码/崩溃/忽略 SIGTERM
  的假 daemon。
- 新增 `make defcompile`:强制编译所有 Vim9 `def`。Vim9 惰性编译会把冷分支里的
  语法/类型错误一直藏到用户真正踩中为止。
- `make check` 现在包含以上两项。

## 0.4.1 - 2026-07-26

- 性能:文件模糊匹配重写为 (score, index) 两阶段——先打分排序,只有进入结果页的条目才克隆路径与计算高亮位置;Utf32 缓冲循环外复用。大仓库(10万+文件)下每次按键少做 O(n) 次字符串分配。

## 0.4.0 - 2026-07-26

- 新增 `:SimpleFinderLines`:模糊搜索当前缓冲区的行,`<CR>` 跳转到对应行(无名缓冲区也可用),预览弹窗以该行为中心。`g:simplefinder_lines_max`(默认 50000)限制收集行数。
- 新增 `:SimpleFinderHelp`:模糊搜索 'runtimepath' 下所有帮助标签,选中后直接 `:help` 打开。
- `:SimpleFinderResume` 支持恢复以上两种本地源。
- 修复:panel 窗口的 buffer 被用户 `:edit` 换走后,再次打开会渲染到隐藏 buffer;现在会检测并新开 panel 窗口。
- 内部:本地源的模糊过滤改用 `matchfuzzypos()` 的 key 匹配,路径重复的条目不再被折叠。

## 0.3.1 - 2026-07-25

- 刷新依赖 lockfile，重建 daemon；行为无变化。

## 0.3.0

- 预览弹窗:实时显示选中文件内容或匹配行上下文,`<C-e>` 开关,`g:simplefinder_preview` 控制默认值
- 多选:`<Tab>`/`<S-Tab>` 标记结果,`<C-q>` 将标记(或全部)结果导出到 quickfix
- 命中高亮:文件名模糊匹配的命中字符与全文搜索的匹配片段在面板中高亮(`SFinderMatch`)
- smart-case:`<C-a>` 在 smart `[sC]` / 忽略 `[aa]` / 敏感 `[Aa]` 三态间循环,`g:simplefinder_smart_case` 默认开启
- 新增 `:SimpleFinderResume` 恢复上次搜索的模式、查询与选项
- 缓冲区模式新增 `<C-d>` 关闭选中 buffer
- 文件扫描改为并行遍历,大项目首次扫描明显加速
- 全文搜索跳过二进制文件,超长行(>512 字节)安全截断
- 修复滚动视口:光标上移时不再整页跳动
- 新增 Vim 帮助文档 `doc/simplefinder.txt` 与端到端功能测试
- 注意:`<Tab>`/`<S-Tab>` 从"上下移动"改为"标记并移动",移动请使用 `<C-j>`/`<C-k>` 或方向键

## 0.2.0

- 增加正则、忽略大小写、隐藏文件和忽略规则实时切换
- 增加加载、错误、耗时、截断及空结果状态
- 支持完整可打印 ASCII 查询和更多项目根配置
- 增加左右布局、选择后关闭、根目录命令及搜索命令
- 将文件扫描和模糊匹配移出异步主线程，并增强取消处理
- 校验搜索根、限制最大结果数、稳定排序全文结果
- 增加 Rust 单元测试、Vim 冒烟测试、CI 和完整文档
