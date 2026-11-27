# 栏量 LanLiang

macOS 菜单栏小工具：显示 Codex 与 Gemini（Google Antigravity 登录）的周剩余额度和 5 小时剩余额度，面板里看套餐、订阅有效期和 Codex 的 Token 用量。

- 原生 Swift + AppKit，面板 SwiftUI；macOS 13+，universal 包，Sparkle 2 自动更新。
- 只读：不改写 `~/.codex`、`~/.gemini` 或钥匙串里的任何东西；只写自己的 `~/.lanliang`。
- 需求契约：`docs/changes/0.1.0.md`。

## Gemini 登录（0.3.14）
- 每个刷新周期用 `/usr/bin/security find-generic-password -s gemini -a antigravity -w` 读 Antigravity 的登录（这一项本来就是 Antigravity 经 `security` 写的，读的时候不弹钥匙串授权窗口）；读不到再看 `~/.gemini/jetski-standalone-oauth-token`、`~/.gemini/antigravity-cli/antigravity-oauth-token`。
- 访问令牌剩不到 15 分钟就用 refresh_token 换新（Antigravity 安装版 OAuth 客户端，值由发版流程从仓库 Secret 注入 Info.plist，源码里没有）；额度接口 401 时强制换新、只重试一次。
- 换新结果只写 `~/.lanliang/gemini-token.json`（600，原子写）；Antigravity 换账号（refresh_token 变了）时跟着换。不写钥匙串、不写 `~/.gemini`。
- 契约：`docs/changes/0.3.14.md`。

## 菜单栏（0.3.2）
每个服务一行：图标、周剩余（主文字色，紧贴图标）、细竖线、5 小时剩余（品牌橙：深色栏 #FF9F0A、浅色栏 #C25400）；没有 5 小时额度时显示灰色「--」。两个服务都开时上下两行，只开一个时单行放大。

## 设置窗口（0.3.0）
面板顶栏的齿轮打开设置窗口（宽 520），三张卡片：
- **监听服务**：Codex、Gemini 可以分别开关，开着的才出现在菜单栏和面板里；关掉的服务不再请求额度和用量（已有缓存保留）。至少保留一个，最后一个开着的开关置灰。只开一个时，菜单栏和面板放大显示这一个（面板去掉页签）。
- **消耗汇总**：开着的服务的累计 Token 相加——Codex 是官方接口返回的全部日用量之和，Gemini 是本机 Antigravity 记录的全部日用量之和。Codex 官方用量拿不到时标「不完整」，总数只含 Gemini。
  - 0.3.1 起，「累计」一行下面是和面板同一个柱状图（每日/每周/每月，分段只在设置里生效、默认每日；累计始终是全部数据，不随分段变）：两个都开时每根柱子 Codex（橙）在下、Gemini（紫 #8E8CF5）在上，悬停显示日期、两家各自用量和合计；只开一个时和面板那家的图一样是单色柱；Codex 拿不到时只画 Gemini 那一段并标「不完整」。
- **通用**：登录时启动、自动检查更新。

## 参考说明
设计时参考了开源项目 [Quosparr](https://github.com/Licoy/Quosparr)（AGPL-3.0）读取了哪些本地文件（`~/.codex/auth.json`、Antigravity 的 OAuth token 文件与钥匙串项）和调用了哪些接口（chatgpt.com `wham/usage`、`wham/profiles/me`，Cloud Code `loadCodeAssist`、`retrieveUserQuotaSummary`），并对照 openai/codex 与 google-gemini/gemini-cli 的公开源码核对格式。本仓库代码全部从零编写，没有包含或改写 Quosparr 的任何代码。

## 开发
- 纯逻辑：`Sources/LanLiangCore`，`swift test` 运行单测。
- 界面：`App/`，`scripts/build.sh VERSION` 在 macOS 上打包。
- CI：推送 master 触发 `.github/workflows/ci.yml`（单测、打包、冒烟、截图）；CI 不注入 OAuth 客户端值，这时应用不换新令牌，单测也不需要真实值。发版 `release.yml` 缺这两个 Secret 会直接失败。

数据来源参考了开源项目 [Quosparr](https://github.com/Licoy/Quosparr)，本项目代码为独立实现。
