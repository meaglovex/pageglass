# 性能验收：0.7 对照进行中

2026-09-29，三款浏览器的完整对照尚未完成，不能据此宣称 Chrome 级速度或更低内存。原生启动、切换、滚动调度、空闲 CPU、捕获耗时及释放的三轮结果已整理到 [原生体验报告](performance-0.7-experience.md)，同时公开白名单内的原始样本。报告保留超过 10% 的回归调查项，没有判定性能验收通过。

## Speedometer 3.1：三组均完成

同机、同系统、同一固定上游源码与适配器；每款三轮，每轮十次迭代、20 个套件、580 个测试步骤。外层视口均为 1280×780，基准内部为 800×600；全程前台、未锁屏、非省电、温控 nominal。分数越高越好。

| 浏览器 | 三轮分数 | 中位数 |
|---|---|---:|
| Pageglass 0.6.0 | 60.32 / 57.13 / 57.33 | 57.33 |
| Pageglass 0.7.0-beta.1 build 9 | 54.44 / 57.06 / 59.62 | 57.06 |
| Chrome 154.0.8037.58 | 58.59 / 58.24 / 58.32 | 58.32 |

build 9 中位数较 0.6 低 0.46%，约为 Chrome 的 0.979 倍；0.7 的轮次波动也更大。单项分数接近不构成全面同级结论，更不能代替启动、切换、内存、视频与网站兼容性。所有迭代都计入，包括较慢的首轮迭代，没有择优删除低分。

[公开原始分数、各套件总时间和环境记录](benchmarks/0.7-speedometer.json)已通过比较工具核对，包含三款二进制、上游源码、适配器、运行器和本地服务器哈希。完整本地记录分别在 `qa-output/benchmark-20260929-201702-b44460/`（0.6）、`qa-output/benchmark-20260929-203550-e7c834/`（0.7 build 9）、`qa-output/benchmark-20260929-201549-9119bd/`（Chrome）。

build 8 的上一批为 59.25 / 53.50 / 59.93，中位数 59.25；修复后重新测得上表 build 9 的三轮，没有沿用旧包或选择较高批次。旧记录在 `qa-output/benchmark-20260929-201804-ff7a31/`。

此前批次 `benchmark-20260929-201348-df13f2` 的第二次 Chrome 启动未得到 benchmark client，整批未生成完成汇总；当时缺少模块加载诊断，根因尚未确定。随后适配器在页面模块加载前安装错误采集，初始化失败会保留资源状态和错误，而非转为成绩；三款均用新适配器重跑上述完整三轮。没有修改上游计时或计分代码，也没有把旧适配器的成绩混入这张表。

## 当前内存阶段数据

固定视口第 3 版（每个标签均实际显示过）已完成 0.6 与 0.7 build 9 各三轮，每轮五个完整物理占用样本，共 18 轮 / 90 次采样。build 9 二进制 SHA256 为 `e24797ea5a0c4aefdece41417af44f062b2672b7d4f33774aaae8774d33cd174`，与本页 Speedometer 被测包相同。

| 全部加载标签 | 0.6 中位数 MiB（轮次范围） | 0.7 build 9 中位数 MiB（轮次范围） |
|---|---:|---:|
| 1 | 144.9（144.9–149.2） | 146.7（146.5–150.3） |
| 5 | 339.9（328.4–464.3） | 276.2（270.8–335.7） |
| 10 | 509.2（444.9–553.5） | 492.2（491.7–618.6） |

[公开阶段样本](benchmarks/0.7-memory-stage.json)明确标记 Chrome 缺失；包括每次采样与按进程名称拆分的物理占用、全部标签显示/就绪证据及环境记录，不含浏览器配置。三组中位数均未超过 10% 回归阈值，但 5 / 10 标签的波动明显，不能只引用中位数差异宣称确定的节省比例，更不能推导对 Chrome 的结论。

完整本地记录为 `qa-output/benchmark-20260929-203741-1bf9f5/`（0.6）与 `qa-output/benchmark-20260929-204006-3ff402/`（build 9）。两组使用同一当前运行器、资源服务器和负载哈希；Chrome 后续也必须匹配这些条件，并取得三轮全部加载、实际显示过的 1 / 5 / 10 标签数据，才能由 `compare-memory.py` 生成三款比较。

build 8 的旧阶段中位数为 146.5 / 341.3 / 493.3 MiB，旧基线为 145.0 / 409.6 / 493.6 MiB。原始记录在 `qa-output/benchmark-20260929-200620-0e0a77/` 和 `qa-output/benchmark-20260929-200951-e055a3/`；服务器脚本哈希已变化，未混入当前表。Chrome 第 3 版批次 `benchmark-20260929-200859-08da34` 在 5 标签时因界面工具只能选中用户正常 Chrome 进程而停止，只完成 1 标签；未生成比较报告，也未操作正常 Chrome 的标签。

## 内存工具的早期记录

下面保留工具迭代的阶段记录，不能与不同版本的测试页面混算。

| 全部加载标签 | 0.6 中位数 MiB | 早期 0.7 中位数 MiB | 变化 |
|---|---:|---:|---:|
| 1 | 145.0 | 147.1 | +1.4% |
| 5 | 283.2 | 271.9 | −4.0% |
| 10 | 471.6 | 488.9 | +3.7% |

此处仅是阶段数据；候选二进制 SHA256 为 `f64e221df70b67bb9ae94c6438050354507c10d6e513c701a9e22e935676868b`。原始记录在 `qa-output/benchmark-20260929-182728-a0f7e5/`、`qa-output/benchmark-20260929-183038-2a68cc/`，每个标签数三轮，每轮五次完整物理内存采样。样本波动明显，不从最低值推导优化结论。

Chrome 在 `benchmark-20260929-183540-9487a6` 取得 1 / 5 标签样本，10 标签仅 9 个页面回报就绪，未采样、未生成完成汇总。运行已中止，不能拼接这些单轮值冒充三轮比较。此前另一次曾因温控变化中止，另一次 footprint 进程采样失败；均未记为完成。运行器现在为未全部就绪设置 120 秒上限并保存缺失标签，不能无限等待或少计页面。

19:32 用独立 Chrome 配置连续三次复查 10 标签启动，全部页面都回报就绪，未复现缺失标签；请求记录和诊断脚本保存在 `qa-output/readiness-20260929-1932/`。这仅验证加载和回传，未采集性能成绩。随后正式运行器再次因 `thermalState=fair` 拒绝启动（退出码 2），原始 `preflight.json` 同目录留存。仍需在温控正常时重跑完整对照，不能据此把此前超时标为已修复。

早期原始窗口测试中，0.6 与 0.7 分别取得三轮样本（`qa-output/benchmark-20260929-181418-36c575/`、`qa-output/benchmark-20260929-182218-e1f75d/`）。复核发现 0.6 有两个后台标签仍报告 778 pt 高度，可见标签为 780 pt；这些样本保留作排查，不作为最终同视口结果。

内存测试页面第 2 版将实际负载放在固定 1280×760 的同源内容区，前台和后台都校验同一尺寸，并记录外层窗口尺寸、页面与容器源码哈希。Chrome 辅助进程在采样中退出或系统 footprint 工具报错时，该样本作废并留下原因，最多重取两次；仍须取得五个完整样本，温控和前台约束不变。这些约束延续到第 3 版。

随后一次正式运行再次遇到 Chrome 10 标签只回报 5 个页面（`benchmark-20260929-193753-618f88`）；已按超时作废。第 3 版保留相同页面和固定视口，增加每页 `seenVisible` 证据：三款浏览器都必须逐一显示过所有标签，并回到首个标签后才开始采样。Pageglass 测试入口已逐一激活；Chrome 启动后，运行器打印 `activate-chrome-tabs`，需通过真实浏览器界面依次切换各测试标签，等待内容出现，再回到第一个标签。未操作或未加载完整的轮次仍超时失败；不关闭 Chrome 的后台调度或资源保护。旧版样本不与这一版混合生成最终比较。

锁屏、前台切换、温控或省电模式影响测量；脚本在这些条件下拒绝开始或使该轮无效。较早的锁屏测试记录保留在文末，不代表当前桌面状态。

## 同负载测量

0.7 的运行器可用 `--pageglass-app <应用路径>` 指向保留的 0.6 安装包；`--engines pageglass` 或 `--engines chrome` 可单独收集基线，默认仍交替测量两款浏览器。`--chrome-window-height` 用于校准 Chrome 的实际页面视口；调整窗口后必须检查各轮结果中的 viewport，不能只比较窗口外框。本机构建通过 LaunchServices 启动时可能等待 Documents 访问提示；`--output-root /tmp/pageglass-benchmarks` 将自有测试配置和输出放在临时目录，不需要为跑分扩大目录权限。完成后可将结果复制回 `qa-output/` 留档。未就绪的启动和失效轮次不计成绩。单引擎运行不会生成两款浏览器的分数比值。前台、锁屏和温控检查始终生效。

使用本机正式 Chrome 与 release Pageglass，每轮独立测试数据，默认 3 轮，交替浏览器顺序。不会关闭或读取用户现有 Chrome 标签与登录。

```sh
cd pageglass
scripts/build.sh
# 下载/校验固定源码，检查环境，不启动测试浏览器
python3 scripts/benchmark/run.py
# 解锁、保持桌面空闲后运行：每轮 10 次迭代
python3 scripts/benchmark/run.py --run
# 分别完整加载 1、5、10 个标签，再各取 5 次物理内存样本
python3 scripts/benchmark/run.py --run --workload memory
```

Speedometer 固定为 [3.1 的具体提交](https://github.com/WebKit/Speedometer/tree/1386415be8fef2f6b6bbdbe1828872471c5d802a)，不跟随 `main`（下载时 main 已是 4.0 alpha）。每次准备时将解压文件逐字节对照原始 ZIP，修改过的源码会被拒绝。源码和许可证保留在忽略的 `qa-output/`，不进入 App 或本仓库发布物。

本地服务器仅在 index 响应中插入开始/结束适配器，计时测试及计分代码不改。适配器通过原 benchmark client 启动，在完成后保存原始 metrics。测试内部 viewport 固定 800×600。运行期切到后台、样本缺失、浏览器退出或请求超时会失败，不能转为 0 分或成功。

内存页面是相同来源的产品工作台夹具：1000 行表格、200 个 SVG 图元、400 行编辑文本。Pageglass测试模式逐个激活并加载所有标签后才报告就绪，不能通过只加载一个标签“胜出”。这是可重复的受控负载，不能代替真实 Figma、文档站、后台及视频等站点矩阵。实际窗口 viewport 会记录在各轮结果中；两个浏览器 viewport 一致后才能接受内存对照。固定内容区在两款浏览器中均完整可见；Chrome 外框高度设为 867 pt，使前台页面与 Pageglass 一样为 1280×780。运行器等待布局稳定，监听页面 resize，检查每个标签的内容视口；采样期间视口变化或汇总时视口不一致都会拒绝比较。

## 物理内存归属

`scripts/benchmark/process_metrics.py` 使用系统 `footprint --noCategories -j`，不将 RSS 当作物理内存。Pageglass的 WebKit XPC 进程父 PID 是 launchd，不能只遍历子进程；脚本先验证 `launchctl print pid/<PID>` 的 creator 是目标Pageglass，再纳入其服务表中的渲染、GPU、网络及其他助手进程。Chrome 纳入子进程以及命令行明确关联本轮独立测试目录的 Crashpad。进程在采样途中退出会报错，不默默漏计。

```sh
python3 scripts/benchmark/process_metrics.py --pid <Pageglass进程ID> --engine pageglass
```

`qa-output/attributed-memory.json` 已通过运行中的Pageglass验证了服务归属与系统物理占用读取。该快照来自锁屏时的已有会话，**不是两款浏览器的同负载对照数据**。

## 原生体验测量探针

`scripts/benchmark/experience.py` 从指定 Git 提交导出独立临时副本，给启动入口加一处显式测试分支，再加入同一份 `ExperienceProbe.swift`。探针位于测试工具目录，不参与正式应用构建；0.6 和 0.7 使用相同探针与自有长页面。保存原提交、插入补丁、探针/页面/可执行文件哈希，结果明确标为插桩构建。测试不读取正常浏览器配置，也不改剪贴板。

```sh
# 先构建两份测试包；命令输出 build 目录
python3 scripts/benchmark/experience.py --source-ref b21b6fdd6be53d31739a7999c50df82233385793
python3 scripts/benchmark/experience.py --source-ref HEAD
# 温控恢复正常后，分别复用上一步输出的目录；正式测量默认三轮
python3 scripts/benchmark/experience.py --build /tmp/pageglass-experience-build-... --run
# 仅排查探针自身；结果始终 accepted=false，不生成正式性能中位数
python3 scripts/benchmark/experience.py --build /tmp/pageglass-experience-build-... --run --diagnostic --rounds 1
```

测量口径：

- 启动：从 LaunchServices 启动请求到应用处于前台、窗口为键窗口、地址栏 field editor 可输入。每轮新进程与空配置；未清空系统文件缓存，不称为磁盘缓存冷启动。前台激活状态最多按 10ms 间隔检查，不等页面加载完才计启动完成。
- 标签：10 个全部加载的标签，30 次原生 `activate`，记录调用到目标页面第二次 `requestAnimationFrame` 回调的间隔。包含原生布局和 WebKit 往返，是可重复的切换代理指标，不等于物理鼠标输入至显示器呈现的延迟。
- 滚动：相同长页面连续四秒按时间滚动，保留每次 rAF 调度间隔、实际滚动距离与视口。rAF 反映页面调度节奏，不冒充屏幕呈现帧时间。
- 空闲：加载完十个标签后等待五秒稳定，原生任务继续休眠，采集十秒内整组进程累计 CPU 时间的增量；记录单核百分比。使用公开的 `proc_pid_rusage`，按 `mach_timebase_info` 换算 Mach 计数，避免 `ps` 百分之一秒舍入影响小幅差异；进程集合或进程启动标识变化使该轮失效。
- 捕获：元素和整页分别从捕获服务调用到三份核心文件落盘计时；不包含人工选区与完成预览操作。保留正常 `latest` 所有权，采集捕获前、元素后、整页后及约 5/15 秒后的总物理内存。
- 释放：清空最新结果、关闭其他九个标签，检查弱引用均释放，再测量剩余一个标签的整组物理内存。系统引擎缓存仍可能保留，不能把每一字节未归零都解释成泄漏。

探针不替代前述分发二进制的 Chrome/Speedometer 对照及真实 UI 操作验收。正式轮次同样要求未锁屏、非省电、温控正常和测试应用保持前台；任一不符则不生成完成汇总。

使用 `compare-experience.py --baseline <0.6结果目录> --candidate <0.7结果目录> --output <报告.json>` 汇总；工具拒绝诊断模式、不完整轮次、不同探针/页面/启动插入代码，以及不同视口或显示器刷新率。插入补丁的上下文随版本而异，其完整哈希分别保存，新增代码本身必须相同。

CPU 单位依据 Apple XNU 的 [fill_task_rusage](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c) 和 [task_power_info_locked](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c)。`python3 scripts/benchmark/test_cpu_time.py` 用独立 `getrusage` 对比实际 CPU 消耗，检查 Apple Silicon 的时钟换算，防止直接把原始 tick 当成纳秒而少计。

## 结果与隔离

每轮保存原始分数、子项、窗口尺寸、系统状态、进程归属、字节占用及浏览器二进制 SHA256。全部轮次完成才生成 summary；Speedometer 结束时的内存不冒充多标签内存测试。结果写入指定的 `--output-root`（默认 `qa-output/benchmark-*`）。运行中的 Chrome profile、控制台日志和任何用户数据不作为公开测量报告上传。

三组全部完成后，用 `scripts/benchmark/compare-memory.py --baseline <0.6结果目录> --candidate <0.7结果目录> --chrome <Chrome结果目录> --output <报告.json>` 验证同一负载哈希、每个标签的固定视口、三轮及每轮五个完整样本，再导出白名单中的测试数据、中位数与范围。未完成的运行不能生成比较报告。

Speedometer 三组全部完成后，使用相同参数调用 `compare-speedometer.py`；它检查上游源码、适配器、运行器、设备、视口、测试数量及每轮至少十个有效分数一致，再导出每轮分数、各子套件总时间与环境记录。运行器记录的 SHA256 用于核对同一测量程序，不能混用改过适配器的成绩。

`--benchmark-plan` 是显式本地测试入口，仅接受回环 HTTP 地址（最多 10 个）；使用独立 BrowserStore 和唯一 WKWebsiteDataStore 标识，不恢复用户会话，也不保存到正常历史/会话文件。Chrome 使用独立 `--user-data-dir`。测试目录和带 UUID 的 WebKit 测试存储暂留用于排查，不自动删除用户网站数据。运行器只结束自己创建并验证身份的测试进程。

## 早期工具验证记录（0.4）

- 官方压缩包提交、解压文件和 SHA256 核对通过。
- 本地 server：index 适配器插入、上游模块原字节传输、结果回传、10 标签结果合并通过协议检查。
- Python/JavaScript 语法与 Swift 构建通过；浏览器原有 6 项单元测试和 38 项 WKWebView 检查通过。
- 外层运行器检测锁屏返回退出码 2；原生测试入口也在加载页面前返回 2，正常 `browser.json` 修改时间保持不变。
- 当时尚未验证正式 Speedometer 完成链路、Chrome 前台状态、viewport 校准和多轮对照；当前进展见本文开头，不能把这条历史记录当作本版结论。

完整验收还需要真实常用网站的加载、滚动帧时间、输入响应、长任务、视频功耗与兼容性；Speedometer 单一分数不代表整个浏览器体验。
