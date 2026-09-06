import Foundation

// MARK: - 官方数据源读取器框架
//
// 每个数据源实现 SourceReader，返回倒计时条目 + 一行状态文字。
// 新增供应商时实现一个 Reader 并注册到 ReaderEngine.all 即可。

struct ReaderResult {
    var items: [SubItem]
    var status: String
}

protocol SourceReader {
    var name: String { get }
    func read() -> ReaderResult
}

final class ReaderEngine {
    static let all: [SourceReader] = [CodexReader(), ClaudeReader(), GrokReader(), ZCodeReader()]

    /// 在后台线程调用：汇总所有官方数据源
    static func refreshAll() -> (items: [SubItem], statuses: [String]) {
        var items: [SubItem] = []
        var statuses: [String] = []
        for reader in all {
            let r = reader.read()
            items.append(contentsOf: r.items)
            statuses.append("\(reader.name)：\(r.status)")
        }
        return (items, statuses)
    }
}

// MARK: - Codex / ChatGPT（官方本地数据）

final class CodexReader: SourceReader {
    let name = "Codex"

    struct RateWindow {
        var usedPercent: Double
        var windowMinutes: Int
        var resetsAt: Date
    }

    struct RatePool {
        var limitID: String
        var limitName: String?      // 模型池名称（如 GPT-5.3-Codex-Spark）；通用池为 nil
        var windows: [RateWindow]
    }

    func read() -> ReaderResult {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let authURL = home.appendingPathComponent(".codex/auth.json")

        guard let authData = try? Data(contentsOf: authURL),
              let auth = try? JSONSerialization.jsonObject(with: authData) as? [String: Any] else {
            return ReaderResult(items: [], status: "未检测到登录（~/.codex）")
        }

        var items: [SubItem] = []
        var plan = ""

        // 1) 订阅到期日：来自 id_token JWT 里的官方 claims
        if let idToken = (auth["tokens"] as? [String: Any])?["id_token"] as? String,
           let claims = Self.jwtPayload(idToken),
           let openai = claims["https://api.openai.com/auth"] as? [String: Any] {
            plan = openai["chatgpt_plan_type"] as? String ?? ""
            if let untilStr = openai["chatgpt_subscription_active_until"] as? String,
               let until = Self.parseISO(untilStr) {
                let planName = plan.isEmpty ? "ChatGPT" : "ChatGPT \(plan)"
                items.append(SubItem(id: "auto:codex:subscription",
                                     name: "\(planName) 订阅",
                                     vendor: "OpenAI",
                                     kind: .subscription,
                                     expiresAt: until,
                                     repeatHours: nil,
                                     source: "codex",
                                     note: "来源：官方 auth.json（JWT 订阅声明）",
                                     alertBeforeMinutes: 60 * 24,
                                     groupID: nil))
            }
        }

        // 2) 额度窗口：官方 rate_limits 按额度池上报（通用池 limit_id="codex"，
        //    模型池带 limit_name 如 "GPT-5.3-Codex-Spark"），与官方使用页一一对应
        if let pools = Self.latestRatePools(), !pools.isEmpty {
            let now = Date()
            for pool in pools {
                let poolLabel = (pool.limitName?.isEmpty == false) ? pool.limitName! : "Codex 通用"
                for w in pool.windows where w.resetsAt > now {
                    items.append(SubItem(id: "auto:codex:\(pool.limitID):\(w.windowMinutes)",
                                         name: "\(poolLabel)·\(Self.windowLabel(w.windowMinutes))",
                                         vendor: "OpenAI",
                                         kind: .window,
                                         expiresAt: w.resetsAt,
                                         repeatHours: Double(w.windowMinutes) / 60.0,
                                         source: "codex",
                                         note: String(format: "官方 rate_limits · 剩余 %.0f%%", 100 - w.usedPercent),
                                         alertBeforeMinutes: 15,
                                         usedPercent: w.usedPercent,
                                         groupID: nil))
                }
            }
        }

        var status = "未发现到期数据"
        if !items.isEmpty {
            status = plan.isEmpty ? "已读取 \(items.count) 项" : "\(plan) · 已读取 \(items.count) 项"
        }
        return ReaderResult(items: items, status: status)
    }

    // MARK: 私有工具

    static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var p = String(parts[1])
        p += String(repeating: "=", count: (4 - p.count % 4) % 4)
        guard let data = Data(base64Encoded: p, options: [.ignoreUnknownCharacters]) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    static func windowLabel(_ minutes: Int) -> String {
        if minutes == 300 { return "5小时限额" }
        if minutes == 10080 { return "每周限额" }
        if minutes >= 1440 && minutes % 1440 == 0 { return "\(minutes / 1440)天限额" }
        if minutes >= 60 && minutes % 60 == 0 { return "\(minutes / 60)小时限额" }
        return "\(minutes)分钟限额"
    }

    /// 扫描最新的 rollout 会话文件，按额度池汇总官方 rate_limits（每池取最后一条事件）
    static func latestRatePools() -> [RatePool]? {
        let sessions = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let files = try? FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }

        var newest: (URL, Date)?
        for case let url as URL in files where url.pathExtension == "jsonl" {
            if let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                if newest == nil || d > newest!.1 { newest = (url, d) }
            }
        }
        guard let file = newest?.0, let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }

        // 每个额度池保留最后一条 rate_limits 事件
        var pools: [String: (limitName: String?, windows: [RateWindow])] = [:]
        raw.enumerateLines { line, _ in
            guard let marker = line.range(of: "\"rate_limits\":") else { return }
            guard let brace = line[marker.upperBound...].firstIndex(of: "{") else { return }
            guard let data = Self.balancedJSON(in: line, start: brace),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

            var windows: [RateWindow] = []
            for key in ["primary", "secondary"] {
                guard let w = obj[key] as? [String: Any],
                      let resets = w["resets_at"] as? Double ?? (w["resets_at"] as? Int).map(Double.init),
                      resets > 0 else { continue }
                let minutes = w["window_minutes"] as? Int ?? (w["window_minutes"] as? Double).map(Int.init) ?? 0
                guard minutes > 0 else { continue }
                let used = w["used_percent"] as? Double ?? 0
                windows.append(RateWindow(usedPercent: used, windowMinutes: minutes,
                                          resetsAt: Date(timeIntervalSince1970: resets)))
            }
            guard !windows.isEmpty else { return }
            let lid = obj["limit_id"] as? String ?? "codex"
            pools[lid] = (obj["limit_name"] as? String, windows)
        }

        guard !pools.isEmpty else { return nil }
        // 通用池排最前，模型池按名称排序
        let ordered = pools.keys.sorted { a, b in
            if (a == "codex") != (b == "codex") { return a == "codex" }
            return a < b
        }
        return ordered.map { RatePool(limitID: $0, limitName: pools[$0]!.limitName, windows: pools[$0]!.windows) }
    }

    /// 从 start（必须是 "{"）提取配平的 JSON 对象
    static func balancedJSON(in s: String, start: String.Index) -> Data? {
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if escaped { escaped = false }
            else if c == "\\" && inString { escaped = true }
            else if c == "\"" { inString.toggle() }
            else if !inString {
                if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 { return String(s[start...i]).data(using: .utf8) }
                }
            }
            i = s.index(after: i)
        }
        return nil
    }
}

// MARK: - Claude Code（本地会话估算 5h 窗口）

final class ClaudeReader: SourceReader {
    let name = "Claude"
    static let windowSeconds: TimeInterval = 5 * 3600

    func read() -> ReaderResult {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeDir = home.appendingPathComponent(".claude")
        guard FileManager.default.fileExists(atPath: claudeDir.path) else {
            return ReaderResult(items: [], status: "未安装 / 未检测到（~/.claude）")
        }

        // Claude Code 不落盘官方重置时间；用会话活动估算当前 5 小时窗口：
        // 最近 5 小时内活跃的会话中，最早的那条消息 = 本窗口起点
        let now = Date()
        let projects = claudeDir.appendingPathComponent("projects", isDirectory: true)
        guard let files = try? FileManager.default.enumerator(at: projects, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return ReaderResult(items: [], status: "已安装，暂无会话数据")
        }

        var windowStart: Date?
        for case let url as URL in files where url.pathExtension == "jsonl" {
            guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(mtime) < Self.windowSeconds else { continue }
            if let first = Self.firstTimestamp(of: url), now.timeIntervalSince(first) < Self.windowSeconds {
                if windowStart == nil || first < windowStart! { windowStart = first }
            }
        }

        guard let start = windowStart else {
            return ReaderResult(items: [], status: "已安装，最近 5 小时无活动")
        }
        let reset = start.addingTimeInterval(Self.windowSeconds)
        guard reset > now else { return ReaderResult(items: [], status: "窗口已重置，待新活动") }

        let item = SubItem(id: "auto:claude:window5h",
                           name: "Claude 5小时窗口(估算)",
                           vendor: "Anthropic",
                           kind: .window,
                           expiresAt: reset,
                           repeatHours: 5,
                           source: "claude",
                           note: "根据本地会话时间估算",
                           alertBeforeMinutes: 15)
        return ReaderResult(items: [item], status: "已估算当前窗口")
    }

    static func firstTimestamp(of url: URL) -> Date? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let ts = obj["timestamp"] as? String else { continue }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: ts) { return d }
            f.formatOptions = [.withInternetDateTime]
            if let d = f.date(from: ts) { return d }
        }
        return nil
    }
}

// MARK: - ZCode（本地暂无到期数据）
// 已核实 ~/.zcode：coding-plan-cache 只有套餐可用状态（无到期时间）；
// config.json 的 OAuth/API Key JWT 无订阅声明；db.sqlite 仅逐次 token 用量。
// 订阅到期时间在智谱服务端。请在悬浮窗手动添加（可用按周划分）。

final class ZCodeReader: SourceReader {
    let name = "ZCode"

    func read() -> ReaderResult {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cacheURL = home.appendingPathComponent(".zcode/v2/coding-plan-cache.json")
        guard let data = try? Data(contentsOf: cacheURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = obj["entryStatus"] as? [String: Any],
              let items = entry["items"] as? [String: Any] else {
            return ReaderResult(items: [], status: "未检测到（~/.zcode）")
        }
        let enabled = items.filter { ($0.value as? [String: Any])?["status"] as? String == "available" }
                            .keys
                            .map { $0.replacingOccurrences(of: "builtin:", with: "") }
                            .sorted()
        if enabled.isEmpty {
            return ReaderResult(items: [], status: "未登录任何套餐")
        }
        return ReaderResult(items: [],
                            status: "已启用 \(enabled.joined(separator: "、"))（到期时间在服务端，请手动添加）")
    }
}

// MARK: - Grok（本地暂无到期数据，框架预留）
// 已核实（auth.json / 92MB 会话 / 日志 / 配置）：Grok CLI 不落盘额度与订阅到期数据，
// 仅 auth.json 有登录账号信息。额度重置卡/订阅请在悬浮窗手动添加。

final class GrokReader: SourceReader {
    let name = "Grok"

    func read() -> ReaderResult {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let authURL = home.appendingPathComponent(".grok/auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ReaderResult(items: [], status: "未检测到登录（~/.grok）")
        }

        // 取第一个账号条目（键形如 "https://auth.x.ai::uuid"）
        var email: String?
        for (_, value) in auth {
            guard let acc = value as? [String: Any] else { continue }
            email = acc["email"] as? String
            if email != nil { break }
        }
        let who = email.map { Self.maskEmail($0) } ?? "已登录账号"
        return ReaderResult(items: [],
                            status: "已登录 \(who)，本地无到期数据（重置卡/订阅请手动添加）")
    }

    static func maskEmail(_ e: String) -> String {
        guard let at = e.firstIndex(of: "@") else { return e }
        let local = String(e[e.startIndex..<at])
        let domain = String(e[at...])
        let head = local.prefix(2)
        return "\(head)***\(domain)"
    }
}
