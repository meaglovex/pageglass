# 技术决定

## 选择系统 WebKit

2026-09-29 核查官方项目及 GitHub API，选择原生 AppKit + WKWebView，复用系统引擎，不 fork 完整浏览器，不引入一个仅包裹 WKWebView 的依赖。系统负责渲染、网络及 GPU 进程；本项目负责导航、标签与捕获。

| 方案 | 维护/许可证核查 | 匹配与成本 |
|---|---|---|
| [antiwork/chromeless](https://github.com/antiwork/chromeless) | 未归档，MIT，最近推送 2026-07-03；仓库仅一个提交 | 同为 Swift/WKWebView，但刻意没有标签、地址栏、查找和下载，适合参考极小壳，不直接 fork |
| [BrowserKit](https://github.com/markbattistella/BrowserKit) | 未归档，MIT，最近推送 2026-09-12 | Swift WebView 包装；核心捕获仍要自己实现，直接用系统 API 更少一层依赖 |
| [CEF](https://github.com/chromiumembedded/cef) | 未归档，最近推送 2026-09-24；CEF BSD 风格许可，依赖另有许可 | Chromium 兼容性优先时合适；需要随应用交付内核与持续跟进安全版本，包体和维护面更大 |
| [Helium macOS](https://github.com/imputnet/helium-macos) | 未归档，GPL-3.0，最近推送 2026-09-27，混合来源保留原许可 | 完整 Chromium 浏览器，复用功能多，但源码构建、补丁维护及分发许可成本明显高于薄壳 |

这些上游只用于选型，**没有复制上游实现或引入第三方包**。若将来引入源码，单独审查许可并保留声明。

WebKit 支持系统 GPU 路径，但不保证所有网站都比 Chromium 快。参考：[WebKit GPU 架构](https://trac.webkit.org/wiki/GPUProcess)、[Apple WKSnapshotConfiguration](https://developer.apple.com/documentation/webkit/wksnapshotconfiguration)、[Helium 构建说明](https://github.com/imputnet/helium-macos/blob/main/docs/building.md)。

## 代码边界

- `BrowserWindow` / `BrowserChrome`：标签生命周期、两行原生工具栏、地址栏、查找栏与临时回执。
- `BrowserActions` / `TabButton` / `AddressSuggestions`：导航菜单、标签排序/恢复与本地地址建议。
- `BrowserStore`：原子写入浏览器数据，延迟合并保存；损坏文件不会被空数据覆盖。
- `LibraryController` / `SettingsController`：书签、历史、下载资料库与设置窗口。
- `WebDelegates`：导航、下载、JS 对话框、文件上传和权限提示。
- `BrowserTab`：每个标签的 WebView 与 KVO；关闭时拆除代理和脚本桥，防止强引用循环。
- `CaptureService`：显式捕获事务、系统截图、长截图拼接、本地包及剪贴板。
- `CaptureAssets` / `Resources/capture-assets.js`：捕获时在隔离世界按页面权限读取资源、限制预算、验证文件格式、保存本地资源并替换引用。
- `InteractionRecording` / `Resources/interaction-recorder.js`：用户显式开启后的限量操作记录；隔离世界事件、短期 DOM 变化观察、前后状态与逐步截图，和最终捕获共享离线资源。
- `Resources/capture.js`：在独立 `WKContentWorld` 选择与序列化 DOM，网页主世界不能调用原生捕获桥。
- `BenchmarkMode`：显式回环性能测试入口，使用独立存储，加载完全部计划标签后报告 PID 和 viewport；锁屏拒绝启动。测量脚本在 `scripts/benchmark/`，不进入应用运行时。
- `SmokeTest` / `BrowserFeatureSmoke`：只通过显式 `--smoke` 参数运行，使用非持久网站数据和内置测试页。

普通浏览无轮询、无 MutationObserver、无后台截图。仅在主动记录交互时，监听点击/变化/激活键并短暂观察 DOM 变化，采样结构与画面；停止、切换标签或页面导航后结束。选取期间注册事件，结束后移除；只在用户开始捕获时计算样式。捕获期间禁用导航/切换，结束恢复页面滚动、动画和临时样式。WebKit 内核沙箱、TLS 校验保持系统默认；私有接口例外仅用于用户授权的本地开发者工具。

## 交付协议

默认剪贴板为 UTF-8 文本，包含本机绝对路径，指向截图、结构、代码与限制说明。这样接收端无需在同一次 paste 中兼容“图片 + 文本”混合剪贴板。单独的图片复制提供普通 PNG/TIFF 剪贴板通道。

捕获数据不是指令。提示词明确要求 Codex 忽略网页中的提示注入，不执行网页脚本。HTML 删除脚本、事件属性和输入值，加 CSP。截图中出现的敏感信息仍由用户选择范围决定；不会把捕获包提交到 Git。

## 资源与兼容性目标

零第三方依赖、系统引擎复用、标签懒恢复和显式释放是控制资源的实现手段，不是内存结论。系统 WebKit 进程必须纳入内存测量，不能只用主进程 RSS 或安装包体积替代性能验收。

Chrome 级验收仍需要相同电脑、相同窗口尺寸/网络/页面集、相同登录状态的多轮测试：Speedometer、页面加载、长任务、滚动帧时间、CPU、总进程内存和视频播放功耗。以真实 PM 页面（文档、设计工具、管理后台）设定产品门槛后再决定是否切换 CEF；不同时背两套引擎。

## 会话与无痕

普通窗口共享系统持久网站数据；每个无痕窗口使用非持久 WKWebsiteDataStore，窗口内标签共享该数据，窗口之间隔离。无痕不自动写历史、下载或恢复会话；显式添加的书签和设置仍是用户主动保存的全局数据。应用不实现自己的 Cookie 或密码库。

恢复只保存 URL、标题与活动位置，不保存未提交表单和页面内存状态。未激活的恢复标签不创建 WebView。运行时关闭标签拆除 KVO、代理和脚本桥；关闭窗口取消其进行中的下载。下载记录是浏览器状态，不代表断点续传能力。

## 离线资源

只在用户启动捕获后调用 [WKWebView.callAsyncJavaScript](https://developer.apple.com/documentation/webkit/wkwebview/callasyncjavascript%3Aarguments%3Ainframe%3Aincontentworld%3Acompletionhandler%3A)，不在普通浏览期间预下载。图片、各计算样式内的 URL、伪元素与所用可读字体先标为资源引用，保存成功后改为捕获包内的相对路径。使用页面 Fetch、`mode: cors` / `credentials: same-origin`，遵守 [Fetch/CORS 规则](https://fetch.spec.whatwg.org/)；没有本机 URLSession 携带 Cookie 绕过页面限制的后备通道。

脚本限制资源数量、并发、单项/总字节和时限；Swift 再校验大小与文件签名。元数据不保存响应头、Cookie 或资源 Base64。外部 SVG 图片先在图像上下文解码为 PNG，不把原 SVG 脚本写入资源文件。资源失败保留原地址并逐项记录，因此不能把部分成功视作完整离线。

选区内使用的本地 SVG symbol/gradient/clip 引用会补入导出定义；原 id、可见伪元素、实时 checked/selected/open 状态保留。仍不运行或导出原业务脚本，也不从当前状态推测未观察到的交互。

## 交互记录一致性

每份文档有独立标识、每次操作有递增序号；截图前后都核对序号，快速操作导致跨状态的截图不写入旧步骤，忙碌或失败步骤保留明确原因。原生端再限制步数、日志大小和画面/结构字节数；重置任务使用 generation 防止异步结果写入新历史。元素选取前先结束记录并保存待处理操作，避免高亮层混入步骤截图。

最多 8 次操作及初始状态，画面与结构总预算 20 MiB；资源仍共用原捕获的 20 MiB 预算。普通键入不记键值，密码事件忽略，表单与可编辑区域的内容不进入日志和 HTML，但截图仍是当前可见画面。预览入口置于捕获根目录，以在 WebKit 明确授权的同一目录内读取步骤及共享资源。

## 网站图标、捕获清理与检查器

标签和书签按站点显示图标。读取页面声明的 icon，再回退同源 favicon.ico；独立无 Cookie URLSession 限制单图 256 KiB、8 秒，ImageIO 缩至 32 像素，内存缓存最多 128 站点。不使用第三方图标服务。

捕获清理仅枚举 Captures 的直接子目录，要求符合本程序命名及完成标志 capture.json，跳过符号链接；不执行或信任网页元数据中的路径。自动按创建时刻计算保留天数，默认关闭，手动和自动都移入系统废纸篓；失败保留并报告。自有剪贴板类型标记所属包，清理不碰其他复制内容。旧设置没有保留期限字段时仍可完整解码。

所有 WebView 开启公开的 isInspectable。用户于 2026-09-29 授权本地版使用私有接口打开真正的检查器，例外集中在 DeveloperTools.swift：配置 _setDeveloperExtrasEnabled:，取得 _inspector，再调用 show / showConsole / attach / close。每次调用都先检查方法存在、参数数量和返回/参数类型，接口不兼容则显示 Safari 备用路径。没有使用 KVC 盲发未知 key，也不调整 WebKit 沙箱、TLS 或页面捕获世界。检查器仅在用户主动打开时加载；关闭标签时关闭其检查器。每个标签使用独立 autoresizing 容器，让 WebKit 给页面和停靠面板分配空间，避免四边 Auto Layout 约束把面板覆盖；切换标签隐藏整个容器。

F12 / ⌥⌘I 切换检查器，⌥⌘J 直接打开 Console，开发菜单和更多菜单也提供入口。WebKit 自带元素、样式、网络、源代码、控制台面板；没有自建仿制面板。实现参照官方 WebKit 的 [_WKInspector](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/_WKInspector.h) 和 [_WKInspectorIBActions](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/_WKInspectorIBActions.h) 方法声明，不复制上游实现。此例外仅适用于本地版，不作为 App Store API 合规保证。
