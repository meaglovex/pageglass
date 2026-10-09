# 0.9 硬件加速状态与检测

入口：**设置 → 性能与图形 → 检测图形能力**。

Pageglass 使用系统 WebKit 自动管理图形加速。0.8 已有实机 WebGL `Apple GPU` 记录；0.9 新增的是状态、检测和诊断报告，不是首次开启 GPU。当前公开 WKPreferences / WKWebViewConfiguration 没有应用级硬件加速总开关，因此页面没有装饰性或私有接口开关。

## 检测内容

- **图形设备**：Metal 返回的设备名称；没有设备时明确显示未检测到。
- **WebGL / WebGL 2**：在本地独立文档编译着色器、绘制三角形并读回一个像素。只有读回值正确才通过。渲染器名称来自该上下文。
- **WebGPU**：执行小型计算并读回预期结果；无适配器、不支持、失败和超时分别保留状态。
- **视频硬解码**：查询系统对 H.264、HEVC 和 AV1 的硬件解码支持。系统支持不代表当前视频实际使用硬解码，也不保证资源一直可用。

“通过”只对应本次检测。它不表示所有网站或每一帧都使用 GPU，不推导帧率、速度、续航或功耗改善。复制的 JSON 报告含时间、应用和系统版本、GPU 设备、测试结果及读回证据，不含当前网址、网页内容、Cookie 或用户输入。

## 生命周期与安全边界

只有点击检测时创建临时 WKWebView。它使用非持久网站数据、本地静态文档、独立内容世界，不加载扩展，不注入当前网页。文档 CSP 禁止网络与页面脚本，导航仅允许检测文件自身。检测完成、超时、离开设置页或关闭设置时停止加载并清除引用；普通浏览无后台检测和轮询。

图形上下文、GPU 缓冲和设备在脚本结束时释放。超时和取消使当前检测失效，迟到回调不能更新界面或覆盖下一次结果。复制动作由用户显式触发，测试模式使用隔离剪贴板。

## 实现依据

- [Apple WKPreferences](https://developer.apple.com/documentation/webkit/wkpreferences)：公开网页行为设置；本项目同时核查本机 SDK 的 WKPreferences.h 与 WKWebViewConfiguration.h。
- [WebKit GPU Process](https://trac.webkit.org/wiki/GPUProcess)：图形与媒体处理进程的架构；存在进程本身不是某项绘制已使用硬件的证据。
- [WebKit ANGLE / WebGL](https://trac.webkit.org/wiki/AngleforWebGL)：WebGL 后端与 Metal 等图形接口。
- [Apple VTIsHardwareDecodeSupported](https://developer.apple.com/documentation/videotoolbox/vtishardwaredecodesupported(_:))：系统硬解码能力查询；SDK 明确说明返回 true 不保证硬件解码资源始终可用。

不使用新的私有 WebKit API，不更改 GPU 黑名单、驱动、安全隔离或第三方页面的图形参数。
