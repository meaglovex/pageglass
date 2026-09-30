# 0.8 标签页声音控制：实现边界与待定方案

2026-09-30。状态：已核查公开 SDK 与编译边界；没有接入或调用私有声音接口。声音需求仍未完成。

## 已确认

macOS 27 SDK、Swift 6.4，以 `arm64-apple-macos14.0` 类型检查：

| 接口 | 结果与用途 |
|---|---|
| `pauseAllMediaPlayback`、`setAllMediaPlaybackSuspended`、`requestMediaPlaybackState` | 类型检查成功。暂停 / 挂起会影响视频进度；播放状态不能证明页面正在发声。不能作为“视频继续播放、仅输出静音”的实现。 |
| `WKWebView.isPlayingAudio`、`WKWebView.isMuted` | 类型检查失败：公开类型没有这两个成员。完整公开头文件也没有页面音频输出静音接口。 |
| `WKWebExtensionTab.isPlayingAudio`、`isMuted`、`setMuted` | 是要求浏览器宿主实现的委托，不会自动控制 WKWebView；不实现时分别返回否或不执行操作。 |
| 麦克风 / 摄像头 capture state | 控制输入采集，不是网页扬声器输出；不能混用。 |

本地编译记录位于忽略目录 `qa-output/audio-api-20260930/result.json`。它只验证 API 可用性，没有播放音频，也没有证明任何私有接口在本机可工作。

依据：[Apple WKWebView](https://developer.apple.com/documentation/webkit/wkwebview/)、[Apple 扩展标签委托](https://developer.apple.com/documentation/webkit/wkwebextensiontab)、本机公开 WebKit 头文件。[WebKit 上游私有头文件](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebViewPrivate.h)另外声明了播放声音状态、页面静音位掩码和设置方法；这是候选技术路径，不能视为公开 API 或兼容性承诺。

## 可审阅的本地版方案

若用户明确扩大当前私有 API 例外，仅在独立的声音适配器封装 `_isPlayingAudio`、`_mediaMutedState`、`_setPageMuted:`。每次使用前验证运行时能力；缺失时不显示可用的静音按钮，并保留可解释的不可用状态。读取和修改只处理音频输出位，保留麦克风、摄像头和屏幕采集等其他位，不改变站点权限。

标签页在确实发声时显示扬声器；静音后显示静音图标，即使暂时没有发声也能取消。右键菜单提供当前标签的静音 / 取消静音。静音状态跟随标签，关闭时释放观察任务；未加载、已释放、无媒体标签不启动常驻高频轮询。扩展音频委托只有在底层控制验证通过后才接入。

验收覆盖 HTML audio / video、Web Audio、iframe、前后台标签、导航、关闭 / 恢复与多个窗口。视频在静音期间继续推进；解除静音不修改网站自身设置的静音 / 音量；不能影响同窗口其他标签或输入采集。先检查接口与状态，再做用户允许的实际音频输出验证；不能以图标切换替代音频验收。macOS 14 / 15.4 仍需对应系统实测。

## 必须确认的范围

[AGENTS.md](../AGENTS.md) 的现有例外原文是：“默认只用公开 API；用户于 2026-09-29 明确授权本地版开发者工具例外使用私有 WebKit 检查器接口，仅限 DeveloperTools.swift 中集中封装并检查运行时兼容。”

此前授权仅针对 F12 检查器，不自动扩大到声音控制。用户可选择允许上述本地版声音适配器，或保留公开 API 约束并明确延期整页静音。没有答复前不调用这些声音私有接口，也不将暂停媒体计为静音完成；其他 0.8 验收继续进行。
