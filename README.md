# 栏量 LanLiang

macOS 菜单栏小工具：显示 Codex 与 Gemini（Google Antigravity 登录）的周剩余额度和 5 小时剩余额度，面板里看套餐、订阅有效期和 Codex 的 Token 用量。

- 原生 Swift + AppKit，面板 SwiftUI；macOS 13+，universal 包，Sparkle 2 自动更新。
- 只读：不改写 `~/.codex`、`~/.gemini` 或钥匙串里的任何东西。
- 需求契约：`docs/changes/0.1.0.md`。

## 参考说明
设计时参考了开源项目 [Quosparr](https://github.com/Licoy/Quosparr)（AGPL-3.0）读取了哪些本地文件（`~/.codex/auth.json`、Antigravity 的 OAuth token 文件与钥匙串项）和调用了哪些接口（chatgpt.com `wham/usage`、`wham/profiles/me`，Cloud Code `loadCodeAssist`、`retrieveUserQuotaSummary`），并对照 openai/codex 与 google-gemini/gemini-cli 的公开源码核对格式。本仓库代码全部从零编写，没有包含或改写 Quosparr 的任何代码。

## 开发
- 纯逻辑：`Sources/LanLiangCore`，`swift test` 运行单测。
- 界面：`App/`，`scripts/build.sh VERSION` 在 macOS 上打包。
- CI：推送 master 触发 `.github/workflows/ci.yml`（单测、打包、冒烟、截图）。

数据来源参考了开源项目 [Quosparr](https://github.com/Licoy/Quosparr)，本项目代码为独立实现。
