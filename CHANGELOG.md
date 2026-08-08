# Changelog

## Unreleased - 2026-08-05

### 截断的 grep 结果变得确定且诚实

- 超出 `g:simplefinder_max_results` 的 grep 现在保留 (path, lnum, col) 排序中
  最靠前的一批。此前 worker 线程按遍历完成顺序追加到共享 Vec,而 drain 是先
  截断再排序,同一查询两次会返回两个不同的子集,`<C-q>` 导出的 quickfix 也随
  线程调度变化——"grep 之后修完 quickfix 里所有匹配"的工作流会静默漏掉匹配。
- daemon 改用按 (path, lnum, col) 定序的有界堆加 `AtomicUsize` 计数,内存不再
  随命中数增长,并回报真实总数:面板显示 `200/5312 results`,不再是无从证伪的
  `200+ results`。
- 为了不让 `.` 这类正则拖垮整棵树,统计有上限(`max` 的 50 倍,至少 10000)。
  触顶时总数是下界,面板明确标记为 `200/10000+ results`。
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
