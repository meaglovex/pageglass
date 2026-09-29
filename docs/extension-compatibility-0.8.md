# 0.8 真实扩展兼容记录

2026-09-30。这是逐条功能的实测记录，不是插件推荐或通用 Chrome 兼容声明。原始上游源码保存在被忽略的 QA 目录，未修改 manifest、脚本或样式。测试仅使用独立、未登录的 QA 配置；没有配置 GitHub token，也没有运行审核、删除仓库等写入动作。首轮构建及回归见 [build 17 报告](validation-data/0.8-escape-extension-ux.json)，Wide GitHub 与 GHUX 补测见 [真实扩展报告](validation-data/0.8-real-extensions.json)。

## GHUX — GitHub UX

- 来源：[jeffreyhaen/ghux-chrome](https://github.com/jeffreyhaen/ghux-chrome)，MIT。
- 旧版 0.6.0：`1e53bfdf1f9c1ea3ffe7a4c167ae27f89adb4df1`，直接用 `git archive` 生成 ZIP。
- 新版 0.7.0：`f99c5ca5d8e41553000442cb81c40d1837aab52f`，从原始目录手动更新。
- 能力：静态隔离世界内容脚本、action popup、`storage.sync` / `storage.local`。声明 `github.com` 与 `api.github.com`，本轮只授予前者。
- 实测环境：Pageglass 0.8.0-alpha.1 build 15、macOS 27.0 (26A428)、ARM64，1280 pt 浅色窗口；公开、未登录的 Pageglass 提交差异页。真正退出重开补测使用最终 build 17。

| 路径 | 实际结果 |
|---|---|
| ZIP 导入及安装权限说明 | 显示名称、0.6.0、storage 与两个网站范围；安装后未自动允许网站 |
| 拒绝 GitHub 权限 | 管理页显示已拒绝；刷新后未出现 GHUX 的页面入口 |
| 仅允许 GitHub | 管理页显示已允许；刷新后差异设置旁出现 GHUX 标记 |
| popup 与设置保存 | 工具栏图标能打开真实弹窗；换行、分栏、minimap、review 与 dashboard 选项可修改，重开弹窗保留 |
| 更新到 0.7.0 | 原身份、工具栏选择、GitHub 授权保留；禁用的 review / dashboard 仍禁用，新版本的 commit 分组选项出现 |
| 撤权 | 管理页显示已拒绝，手动刷新后 GHUX 页面标记消失、差异正文恢复 |
| 差异阅读 | **失败**：启用后行号挤成竖列、正文不可正常阅读；换行开关两种状态以及关闭 split / minimap 后仍有问题，0.7.0 未消除 |
| 真正退出重开 | build 17 恢复工具栏入口；弹窗保留换行 / split / minimap / review / dashboard 关闭及 commit 分组开启，GitHub 拒绝权限保留 |
| build 19 补测 | 重启后同一公开统一差异页未复现竖列异常；换行开关实际改变代码换行。但授权刷新后控制台出现 `Can't create duplicate variable: 'PR_PAGE_RE'`，原因未确定 |
| 停用、卸载 | build 19 实际停用后动作禁用；未勾选删除数据，移除程序后工具栏入口消失，刷新无 GHUX 页面标记；真正退出后登记为停用且无程序副本 |

结论：**部分宿主链路通过，插件功能兼容未通过，不进入已支持列表。** build 19 没有针对 GHUX 修改宿主或插件；一次未复现不能说明原布局问题已修复，重复声明错误也未关闭。尚未确定是上游与当前 GitHub DOM 不匹配，还是 WebKit 差异；没有给宿主添加网站专用补丁掩盖失败。未测试 token、GraphQL、审核、删除仓库与全部 diff 模式。

## YouTube Shorts Blocker

- 来源：[ramonmello/youtube-shorts-blocker](https://github.com/ramonmello/youtube-shorts-blocker)，MIT。
- 旧版 1.0.0：`a1df8e79757cca8dd609abc43f8c1ff4327fe8bf`，原始 ZIP；新版 1.0.1：`3e0d05688c49964cdc91eb83af4f11f2591b501b`，原始目录手动更新。
- 只有 `https://www.youtube.com/*` 的静态 JS / CSS，无 popup、后台 worker 或额外 API 权限。
- 范围：macOS 27.0 (26A428)、ARM64，1280 pt 浅色窗口，未登录的桌面 YouTube 首页。安装、初次拒绝 / 允许使用 build 16，后续更新、生命周期与恢复使用最终 build 17。

| 路径 | 实际结果 |
|---|---|
| ZIP 安装 1.0.0 | 正确显示名称、版本、网站范围与无额外 API 权限；网站未自动授权 |
| 拒绝 YouTube | 显示已拒绝；刷新后首页 Shorts 入口仍可见 |
| 允许 YouTube | 显示已允许；刷新后 Shorts 入口隐藏，其他导航保持 |
| 真正退出重开 | 应用进程退出后重新启动，1.0.0 仍启用，刷新首页仍隐藏 Shorts |
| 无 action 的入口 | 拼图菜单显示“网站权限…”，打开对应扩展详情；没有可点击的空弹窗动作，常驻工具栏选项禁用 |
| 更新 1.0.0 → 1.0.1 | 管理页版本更新、站点授权保留；刷新仍隐藏 Shorts |
| 撤销权限 | 显示已拒绝，刷新后 Shorts 入口恢复 |
| 停用及重启 | 重新允许后停用，刷新恢复 Shorts；真正退出重开后仍停用，集合菜单不列为运行中 |
| 重新启用及重启 | 刷新隐藏 Shorts，真正退出重开后仍启用并隐藏 |
| 移除程序、保留数据 | 程序进入废纸篓，管理页显示“已移除 · 数据保留”；刷新后 Shorts 入口恢复，未勾选永久删除数据 |

结论：**首页 Shorts 导航隐藏功能的安装到卸载流程通过。** 未验证搜索结果卡片、无限滚动、登录态、所有推荐区和直接 Shorts 视频页面，不作插件全部行为兼容承诺。

## Wide GitHub

- 来源：[xthexder/wide-github](https://github.com/xthexder/wide-github)，MIT。
- 旧版 1.7.3：`3d29df23e70544b9be9c8f1c4176a2c311a288ad`；新版 1.7.4：`5540c3fcab9322fa8e593316cd426349ab168bec`。
- 按上游 Makefile 的 Chrome 文件清单生成根目录 ZIP，共 10 个原始文件；没有修改 manifest、脚本、CSS 或执行仓库构建脚本。
- 能力：静态 JS / CSS、无 popup 的 action、MV3 worker、runtime / tabs 消息及 action 图标更新；无额外 API 权限。声明 GitHub 与 Gist，本轮只允许 GitHub。
- 实测环境：Pageglass 0.8.0-alpha.1 build 19，macOS 27.0 (26A428)、ARM64，1440 pt 深色窗口；未登录的公开 Pageglass 仓库主页。

| 路径 | 实际结果 |
|---|---|
| ZIP 安装 1.7.3 | 权限说明正确，安装后没有网站授权；手动选择显示工具栏 |
| 拒绝 GitHub | 管理页显示已拒绝；刷新后正文宽 1280 CSS px，最大宽度 1280 px |
| 授权及工具栏开关 | 只授权 GitHub；实际开关后正文由 1280 扩到 1440 CSS px，最大宽度变为 none；截图检查内容扩宽，未出现额外空弹窗 |
| 更新 1.7.3 → 1.7.4 | 同一扩展身份、GitHub 授权和工具栏偏好保留；刷新仍为 1440 px |
| 撤权 | 显示已拒绝；刷新后正文恢复 1280 px，无扩展改写 |
| 停用及真正重启 | 重新授权后停用，动作从集合和工具栏移除；进程退出再启动仍停用，正文 1280 px |
| 重新启用及真正重启 | 刷新正文恢复 1440 px；进程退出再启动，1.7.4、授权和工具栏入口保留，正文仍为 1440 px |
| 保留数据卸载 | 未勾选删除数据；显示“已移除 · 数据保留”，工具栏入口消失，刷新正文恢复 1280 px；退出后的登记不再包含程序副本 |

结论：**公开仓库主页扩宽及 action 开关的安装到卸载流程通过。** 数值来自实际页面的只读布局查询，并与截图核对。上游开关只保存在 worker 变量中，worker 重启后默认开启；不将该行为描述为宿主保存了开关设置。Gist、登录态、全部 GitHub 路由、多窗口传播及长时间 worker 唤醒未验收。

## 未进入运行验证的候选

以下是按原始 manifest 的准入检查，不将其改写为可安装后宣称兼容。

| 项目 / 固定提交 | 当前边界 |
|---|---|
| [JSON Formatter](https://github.com/callumlocke/json-formatter/tree/0e71cdcf4c0d6eb32b83374160822f245568a014) 0.9.4，BSD-3-Clause | 需要 MAIN world 脚本、webRequest 与 unlimitedStorage，超出 0.8 准入范围 |
| [TaylorHo Shorts Blocker](https://github.com/TaylorHo/youtube-shorts-blocker/tree/95edd48b198f65c12b13e8dd20191e75359b2742) 0.2.1，MIT | 需要 scripting，当前不提供程序化注入 |
| [Dyslexaid](https://github.com/prathammukewar/dyslexaid/tree/e11dbd5fff20b017a9ec5d01f94717260764747f) 1.5.0，MIT | 需要 scripting，不能仅因含静态内容脚本就认定兼容 |

目前两个未修改的真实扩展各有一条明确功能范围的安装到卸载流程通过：Shorts Blocker 首页导航隐藏、Wide GitHub 公开仓库主页扩宽。该结果补齐真实样本生命周期证据，不表示两个插件全部功能或通用 Chrome 扩展兼容。更广页面、多窗口、系统版本及性能仍按 [0.8 发布要求](plan-0.8.md) 验收。
