# 性能验收：0.7 对照进行中

2026-09-29，三款浏览器的完整对照尚未完成，不能据此宣称 Chrome 级速度或更低内存。固定 1280×760 负载的 0.6 与早期 0.7 候选已完成各三轮；当前新增体验修复后的候选尚待重测。

| 全部加载标签 | 0.6 中位数 MiB | 早期 0.7 中位数 MiB | 变化 |
|---|---:|---:|---:|
| 1 | 145.0 | 147.1 | +1.4% |
| 5 | 283.2 | 271.9 | −4.0% |
| 10 | 471.6 | 488.9 | +3.7% |

此处仅是阶段数据；候选二进制 SHA256 为 `f64e221df70b67bb9ae94c6438050354507c10d6e513c701a9e22e935676868b`。原始记录在 `qa-output/benchmark-20260929-182728-a0f7e5/`、`qa-output/benchmark-20260929-183038-2a68cc/`，每个标签数三轮，每轮五次完整物理内存采样。样本波动明显，不从最低值推导优化结论。

Chrome 在 `benchmark-20260929-183540-9487a6` 取得 1 / 5 标签样本，10 标签仅 9 个页面回报就绪，未采样、未生成完成汇总。运行已中止，不能拼接这些单轮值冒充三轮比较。此前另一次曾因温控变化中止，另一次 footprint 进程采样失败；均未记为完成。运行器现在为未全部就绪设置 120 秒上限并保存缺失标签，不能无限等待或少计页面。

19:32 用独立 Chrome 配置连续三次复查 10 标签启动，全部页面都回报就绪，未复现缺失标签；请求记录和诊断脚本保存在 `qa-output/readiness-20260929-1932/`。这仅验证加载和回传，未采集性能成绩。随后正式运行器再次因 `thermalState=fair` 拒绝启动（退出码 2），原始 `preflight.json` 同目录留存。仍需在温控正常时重跑完整对照，不能据此把此前超时标为已修复。

早期原始窗口测试中，0.6 与 0.7 分别取得三轮样本（`qa-output/benchmark-20260929-181418-36c575/`、`qa-output/benchmark-20260929-182218-e1f75d/`）。复核发现 0.6 有两个后台标签仍报告 778 pt 高度，可见标签为 780 pt；这些样本保留作排查，不作为最终同视口结果。

内存测试页面第 2 版将实际负载放在固定 1280×760 的同源内容区，前台和后台都校验同一尺寸，并记录外层窗口尺寸、页面与容器源码哈希。Chrome 辅助进程在采样中退出或系统 footprint 工具报错时，该样本作废并留下原因，最多重取两次；仍须取得五个完整样本，温控和前台约束不变。三款版本正在用这一负载重新测量。

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

## 结果与隔离

每轮保存原始分数、子项、窗口尺寸、系统状态、进程归属、字节占用及浏览器二进制 SHA256。全部轮次完成才生成 summary；Speedometer 结束时的内存不冒充多标签内存测试。结果写入指定的 `--output-root`（默认 `qa-output/benchmark-*`）。运行中的 Chrome profile、控制台日志和任何用户数据不作为公开测量报告上传。

三组全部完成后，用 `scripts/benchmark/compare-memory.py --baseline <0.6结果目录> --candidate <0.7结果目录> --chrome <Chrome结果目录> --output <报告.json>` 验证同一负载哈希、每个标签的固定视口、三轮及每轮五个完整样本，再导出白名单中的测试数据、中位数与范围。未完成的运行不能生成比较报告。

`--benchmark-plan` 是显式本地测试入口，仅接受回环 HTTP 地址（最多 10 个）；使用独立 BrowserStore 和唯一 WKWebsiteDataStore 标识，不恢复用户会话，也不保存到正常历史/会话文件。Chrome 使用独立 `--user-data-dir`。测试目录和带 UUID 的 WebKit 测试存储暂留用于排查，不自动删除用户网站数据。运行器只结束自己创建并验证身份的测试进程。

## 早期工具验证记录（0.4）

- 官方压缩包提交、解压文件和 SHA256 核对通过。
- 本地 server：index 适配器插入、上游模块原字节传输、结果回传、10 标签结果合并通过协议检查。
- Python/JavaScript 语法与 Swift 构建通过；浏览器原有 6 项单元测试和 38 项 WKWebView 检查通过。
- 外层运行器检测锁屏返回退出码 2；原生测试入口也在加载页面前返回 2，正常 `browser.json` 修改时间保持不变。
- **未验证**：正式 Speedometer 完成链路、Chrome 测试窗口前台状态、viewport 校准和多轮对照结果。当前没有性能合格结论。

完整验收还需要真实常用网站的加载、滚动帧时间、输入响应、长任务、视频功耗与兼容性；Speedometer 单一分数不代表整个浏览器体验。
