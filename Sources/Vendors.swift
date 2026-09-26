import Foundation

// MARK: - 厂商额度重置规则知识库
// 依据公开文档与社区调研（详见 RESEARCH.md，2026-09 检索），供编辑表单提示、
// 保存管线自动补全重置节奏与反向厂商识别。
// 厂商规则可能随官方政策调整，条目 note/提示仅供参考；以各官方页面为准。

/// 机器可读的重置规则候选：保存推断管线据此生成伴生重置窗口
struct ResetRuleCandidate: Equatable {
    let rule: ResetRule          // .rolling / .calendarMonth / .calendarWeek / .anchorMonth
    let param: Int?              // calendarWeek=星期几(1=周一)；calendarMonth/anchorMonth=几号；rolling=nil
    let repeatHours: Double?     // rolling 档的小时数（如 Codex 5小时窗口=5，Claude 5h=5，周重置=168）
    let explain: String          // 一句话中文说明（用于 UI 预览）
}

enum VendorResetKnowledge {
    struct Rule {
        let match: [String]        // 供应商名/条目名包含匹配（不区分大小写）
        let canonical: String      // 规范供应商名（vendor(for:) 反向识别结果）
        let hint: String           // 表单提示行（一句话）
        let source: String         // 出处
        let candidate: ResetRuleCandidate?   // nil = 规则无把握，宁缺毋滥（不生成伴生窗口）
    }

    static let rules: [Rule] = [
        Rule(match: ["OpenAI", "ChatGPT", "Codex"], canonical: "OpenAI",
             hint: "OpenAI：5小时窗口自首次使用滚动；周额度自周期内首次使用起7天滚动（非固定日历日）",
             source: "help.openai.com / community.openai.com",
             candidate: ResetRuleCandidate(rule: .rolling, param: nil, repeatHours: 5,
                                           explain: "OpenAI：5小时额度窗口，自首次使用起滚动")),
        Rule(match: ["Anthropic", "Claude"], canonical: "Anthropic",
             hint: "Claude：5小时滚动窗口（本应用按本地会话估算）",
             source: "本应用本地估算",
             candidate: ResetRuleCandidate(rule: .rolling, param: nil, repeatHours: 5,
                                           explain: "Claude：5小时滚动窗口")),
        Rule(match: ["xAI", "Grok"], canonical: "xAI",
             hint: "Grok：短期约2小时滚动窗口 + 付费周限额（官方FAQ）",
             source: "docs.x.ai/grok/faq",
             candidate: ResetRuleCandidate(rule: .rolling, param: nil, repeatHours: 2,
                                           explain: "Grok：约2小时滚动窗口")),
        Rule(match: ["千问", "Qwen", "阿里云", "通义"], canonical: "阿里云",
             hint: "通义千问：每周一00:00(UTC+8)重置周额度；每月「订阅日」00:00重置月额度 → 建议 calendarWeek / anchorMonth",
             source: "help.aliyun.com/zh/model-studio/coding-plan",
             candidate: ResetRuleCandidate(rule: .calendarWeek, param: 1, repeatHours: nil,
                                           explain: "通义千问：每周一 00:00 重置周额度")),
        Rule(match: ["智谱", "GLM", "ZCode", "BigModel"], canonical: "智谱",
             hint: "智谱 GLM/ZCode：5小时滚动 + 自下单日7天周期；无固定月日重置 → rolling；端内有重置卡",
             source: "docs.bigmodel.cn/cn/coding-plan/faq",
             candidate: ResetRuleCandidate(rule: .rolling, param: nil, repeatHours: 5,
                                           explain: "智谱 GLM：5小时积分滚动刷新")),
        Rule(match: ["中转站"], canonical: "中转站",
             hint: "中转站：按购买页说明手动设置——多为「下单日滚动」或「固定日历日重置」两种之一",
             source: "购买页",
             candidate: nil),   // 规则因站而异，宁缺毋滥
    ]

    /// 供应商名包含匹配，返回第一条命中的提示；未命中返回通用提示
    static func hint(for vendor: String) -> String? {
        let v = vendor.lowercased()
        return rules.first { rule in rule.match.contains { v.contains($0.lowercased()) } }?.hint
    }

    /// 机器可读的最佳重置规则候选；无把握的厂商返回 nil（调用方不生成重置窗口）
    static func bestCandidate(for vendor: String) -> ResetRuleCandidate? {
        let v = vendor.lowercased()
        return rules.first { rule in rule.match.contains { v.contains($0.lowercased()) } }?.candidate
    }

    /// 反向识别：条目名称/供应商名含关键词 → 规范供应商名（如名称含 "Codex" → "OpenAI"）；未命中返回 nil
    static func vendor(for nameOrVendor: String) -> String? {
        let v = nameOrVendor.lowercased()
        return rules.first { rule in rule.match.contains { v.contains($0.lowercased()) } }?.canonical
    }
}
