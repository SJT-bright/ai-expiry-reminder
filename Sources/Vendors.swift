import Foundation

// MARK: - 厂商额度重置规则知识库
// 依据公开文档与社区调研（详见 RESEARCH.md，2026-09 检索），供编辑表单提示与文档生成。
// 厂商规则可能随官方政策调整，条目 note/提示仅供参考；以各官方页面为准。

enum VendorResetKnowledge {
    struct Rule {
        let match: [String]        // 供应商名包含匹配（不区分大小写）
        let hint: String           // 表单提示行（一句话）
        let suggest: String        // 建议重置模型
        let source: String         // 出处
    }

    static let rules: [Rule] = [
        Rule(match: ["OpenAI", "ChatGPT", "Codex"],
             hint: "OpenAI：5小时窗口自首次使用滚动；周额度自周期内首次使用起7天滚动（非固定日历日）",
             suggest: "rolling", source: "help.openai.com / community.openai.com"),
        Rule(match: ["Anthropic", "Claude"],
             hint: "Claude：5小时滚动窗口（本应用按本地会话估算）",
             suggest: "rolling", source: "本应用本地估算"),
        Rule(match: ["xAI", "Grok"],
             hint: "Grok：短期约2小时滚动窗口 + 付费周限额（官方FAQ）",
             suggest: "rolling", source: "docs.x.ai/grok/faq"),
        Rule(match: ["千问", "Qwen", "阿里云", "通义"],
             hint: "通义千问：每周一00:00(UTC+8)重置周额度；每月「订阅日」00:00重置月额度 → 建议 calendarWeek / anchorMonth",
             suggest: "calendarWeek / anchorMonth", source: "help.aliyun.com/zh/model-studio/coding-plan"),
        Rule(match: ["智谱", "GLM", "ZCode", "BigModel"],
             hint: "智谱 GLM/ZCode：5小时滚动 + 自下单日7天周期；无固定月日重置 → rolling；端内有重置卡",
             suggest: "rolling", source: "docs.bigmodel.cn/cn/coding-plan/faq"),
        Rule(match: ["中转站"],
             hint: "中转站：按购买页说明手动设置——多为「下单日滚动」或「固定日历日重置」两种之一",
             suggest: "rolling 或 calendarMonth", source: "购买页"),
    ]

    /// 供应商名包含匹配，返回第一条命中的提示；未命中返回通用提示
    static func hint(for vendor: String) -> String? {
        let v = vendor.lowercased()
        return rules.first { rule in rule.match.contains { v.contains($0.lowercased()) } }?.hint
    }

    static func suggest(for vendor: String) -> String? {
        let v = vendor.lowercased()
        return rules.first { rule in rule.match.contains { v.contains($0.lowercased()) } }?.suggest
    }
}
