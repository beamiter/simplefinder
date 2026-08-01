# Changelog

## Unreleased - 2026-08-01

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
