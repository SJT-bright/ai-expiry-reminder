# ⏳ AI 到期提醒

一个**体积极小的 macOS 原生悬浮窗应用**（约 390 KB，无任何运行时依赖），实时展示你所有 AI 订阅与额度窗口的**到期时间倒计时**。

平时它吸附在**屏幕右上角边缘**，只是一个 54×18 的迷你药丸，显示最近一个到期项的紧凑倒计时；点击才展开成紧凑面板；鼠标离开 8 秒后自动收回药丸状态。添加 / 编辑 / 删除 / 通知配置都在**设置后台**完成。

## 功能

- **贴边吸附药丸**：54×18 迷你条贴住屏幕右缘，几乎不占地方；倒计时文字直接染色（红/绿），扫一眼就知道急不急。
- **紧凑展开面板**：点击药丸展开（238pt 宽）。每行 = 状态点 + 名称 + 倒计时（右对齐）+ 小字「供应商 · 到期时间 · 来源」。无多余留白。
- **颜色规则**：**剩余不足 2 天 → 红色，其余全绿**。
- **自动读取官方本地数据**（无网络请求）：
  - **Codex / ChatGPT**：从 `~/.codex/auth.json` 的官方 JWT 读出**订阅到期日**；从最新会话的官方 `rate_limits` 读出**额度窗口重置时间**（5 小时窗口 / 周窗口，含已用百分比）。
  - **Claude Code**：检测 `~/.claude`，按本地会话活动**估算**当前 5 小时窗口重置时间。
  - **Grok**：检测 `~/.grok` 登录状态（其 CLI 不落盘限流数据，重置卡/订阅请手动添加）。
- **手动记录任意订阅**：Grok 重置卡、中转站、各种会员——买了立刻记一笔。支持**周期窗口自动滚动**（如 5 小时窗口到期自动滚到下一轮）。
- **到期预警**：每条可设提前提醒分钟数，触发时弹**系统通知**，并可推送**飞书群机器人**。
- **菜单栏 ⏳ 图标**：唤回悬浮窗、设置后台（⌘,）、刷新、开机自启、退出。

## 快速开始

```bash
./build.sh          # 编译并打包为 build/AI到期提醒.app（仅需 macOS 自带 swiftc，无第三方依赖）
open "build/AI到期提醒.app"
open "build/AI到期提醒.app" --args --settings   # 启动时直接打开设置后台
```

要求：macOS 13+，安装过 Xcode Command Line Tools（`xcode-select --install`）。

## 自测渲染（改 UI 前先跑）

```bash
./test_render.sh    # 离屏渲染悬浮窗(展开/收起)、设置后台、添加表单 → build/render/*.png
```

人工检查 PNG 确认无重叠/裁切后再交付。悬浮窗内部为纯手动布局（Auto Layout 在无边框面板上会把窗口求解成 0×0，勿改回）。

## 界面

| 状态 | 说明 |
|---|---|
| 药丸（默认） | 54×18，贴右缘。显示最近到期项的紧凑倒计时，按红/绿染色。点击展开 |
| 展开面板 | 顶部：⏳ ＋ ⟳ ⚙ ✕（添加/刷新/设置/隐藏）。下方为倒计时列表，点击条目可编辑（官方条目弹说明） |
| 设置后台 | 表格管理全部条目（双击编辑）；底部：飞书 Webhook + 测试发送、开机自启、打开数据文件夹 |

## 常驻机制

应用默认以 **LaunchAgent 常驻**（`~/Library/LaunchAgents/com.sijunting.ai-expiry-reminder.plist`）：

- **登录自启**（RunAtLoad）
- **被杀/崩溃自动重启**（KeepAlive=true，强杀后 1 秒内拉起）
- 菜单「退出」在常驻模式下也会被自动重启——这是设计行为；**彻底关闭**请先在设置里取消勾选「常驻」，应用会以不受守护模式重启一次
- 单实例：手动重复打开会被 launchd 实例接管收敛，不会出现双窗口
- agent 实例的日志输出到 `/tmp/aireminder.log`

菜单栏 ⏳ 和设置后台的「常驻」开关可安装/移除该 LaunchAgent。

## 数据与文件

- 条目与设置：`~/Library/Application Support/AI到期提醒/state.json`
- 官方数据每 60 秒自动重新读取；「剩余」不足 2 天在界面标红。
- ✕ 只是隐藏悬浮窗，菜单栏 ⏳ 可随时唤回。

## 如何接入新的官方数据源

在 `Sources/Readers.swift` 中实现 `SourceReader` 协议并注册到 `ReaderEngine.all`：

```swift
final class MyProviderReader: SourceReader {
    let name = "MyProvider"
    func read() -> ReaderResult {
        // 读取本地配置 / 会话文件，解析出到期时间
        return ReaderResult(items: [/* SubItem(...) */], status: "已读取 N 项")
    }
}
```

`SubItem` 关键字段：`expiresAt`（到期时间）、`kind`（`.subscription` 一次性 / `.window` 周期滚动）、`repeatHours`（周期小时数）、`alertBeforeMinutes`（提前提醒分钟数）。

## 飞书机器人

1. 在飞书群里添加「群机器人」，复制 Webhook 地址。
2. 设置后台粘贴到「飞书群机器人 Webhook」，点「测试发送」。
3. 条目进入预警窗口会自动推送汇总消息。

## 已知限制 / Roadmap

- Grok 官方限流数据本地不可读，当前为手动记录；后续可接官方接口。
- Claude 的 5 小时窗口为本地会话估算，非官方精确值。
- ChatGPT 订阅到期日来自 Codex CLI 本地缓存，长期不使用 Codex 会滞后（跑一次 Codex 即刷新）。

## 开源许可

MIT License，见 [LICENSE](LICENSE)。欢迎 Issue / PR。
