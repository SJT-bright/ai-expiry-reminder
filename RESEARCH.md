# 各厂商额度重置规则调研（2026-09 检索）

> 结论用于本应用「重置模型」建模。厂商政策可能随时调整，以官方页面为准。
> 模型分类对应本应用：`rolling`（自锚点滚动 N 小时/天）/ `calendarMonth`（每月固定日 00:00）/ `calendarWeek`（每周固定星期 00:00）/ `anchorMonth`（每月「订阅日」00:00）。

## 一、OpenAI（ChatGPT / Codex）

- **5 小时窗口**：自周期内**首次使用**起算 5 小时滚动，不是固定整点。
- **周额度**：自周期内首次使用起 **7 天滚动**，重置日会随周期"漂移"，不锚定日历日。
- 5h 与周额度是两个独立节流阀；可用 `/status` 或 Usage 页查看确切重置时间；官方提供付费立即重置（仅周额度触发时）。
- 模型归类：`rolling`（周额度=锚定首用的 168h 滚动）。

出处：[OpenAI Help Center — Codex rate limit resets](https://help.openai.com/en/articles/20001507-paid-weekly-work-and-codex-rate-limit-resets)、[OpenAI Community — Codex revolving window](https://community.openai.com/t/codex-revolving-window-broken/1369681)、[laplusda — Codex usage limit reset date](https://laplusda.com/en/posts/codex-usage-limit-reset-date/)。

## 二、xAI（Grok）

- 短期限额：约 **2 小时滚动窗口**（消息/图像各有独立窗口），额度随最早使用滑出窗口而恢复。
- 付费功能存在**周限额**（官方 FAQ），达到后暂停至周周期重置；曾有过全量手动重置事件。
- 未发现官方"每月固定日重置"。
- 模型归类：`rolling`（短期）+ 周（滚动/周锚定，官方未明示锚点细节）。

出处：[docs.x.ai/grok/faq](https://docs.x.ai/grok/faq)、[docs.x.ai — rate limits](https://docs.x.ai/developers/rate-limits)、[Reddit r/grok 周 limit 讨论串](https://www.reddit.com/r/grok/)。

## 三、阿里云通义千问（Qwen Coding Plan）

- **每周额度：每周一 00:00:00（UTC+8）固定重置** → `calendarWeek`（param=周一）。
- **每月额度：下一个「订阅日」00:00（UTC+8）重置**——按订阅当天日期锚定（1 月 15 日订阅 → 每月 15 日 00:00 重置），不是每月 1 号 → `anchorMonth`。
- 另有每 5 小时滚动请求限制；三重限流（5h/周/月），超限拒绝请求不产生费用。
- 用户例子印证：若购买页宣称「每月 17 号重置」而 15 号买入，则 15→17 为首个不足额周期 → 这属于 `calendarMonth`（与千问的订阅日锚定不同，属于自然月锚定）。

出处：[阿里云官方文档 — Coding Plan 概述](https://help.aliyun.com/zh/model-studio/coding-plan)、[Coding Plan FAQ](https://www.alibabacloud.com/help/zh/model-studio/coding-plan-faq)。

## 四、智谱 GLM / ZCode（Coding Plan）

- **5 小时积分**：消耗后 5 小时动态刷新（滚动，非固定整点）。
- **周积分**：自**套餐下单时**起算，7 天一个周期 → `rolling`（锚定下单时间）。
- 无"每月固定日期重置"；官方提供**端内重置卡**（5 小时+周额度立即回满），偶有活动性全量重置。
- 模型归类：`rolling`。

出处：[智谱开放文档 — 套餐概览](https://docs.bigmodel.cn/cn/coding-plan/overview)、[官方 FAQ](https://docs.bigmodel.cn/cn/coding-plan/faq)、[ZCode 使用统计](https://zcode.z.ai/cn/docs/usage-stats)。

## 五、对"说一个数字"的建模结论

- 输入「17」+ 模型 `calendarMonth`：下一次重置 = 最近一个未来的 17 号 00:00（本地时区）；31 号在小月自动钳到月末。
- 输入「1」+ 模型 `calendarWeek`：每周一 00:00 重置（千问式）。
- 「15 号买入 → 15→17 首段不足额」：`calendarMonth` 天然表达（锚点=17 号日历日，与购买日无关）；若是「按购买日每 30 天」则是 `rolling`（720h）——购买时选择模型即可。

## 六、其他（未逐一深查，后续补充）

- Google（Gemini）付费层：多为按天/滚动限额，规则变动频繁，暂建议 `rolling` 手动建模。
- 中转站/代理：按购买页说明，两种模型都可能出现。
