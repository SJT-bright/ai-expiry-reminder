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

// MARK: - 本地会话文件只读工具

/// 官方 CLI 的会话 jsonl 会长到几百 MB 且正在被持续追加，所以读取必须：
/// ① 只读尾部若干 MB，并从第一个完整行对齐（半行不能交给 JSONSerialization）；
/// ② lossy 解码：`String(contentsOf:encoding:.utf8)` 遇到被截断的多字节字符会让整读失败，
///    返回 nil 后额度条目整块消失；`String(decoding:as:UTF8.self)` 只坏掉那一个字符。
/// 全程只读：不写、不改、不移动 ~/.codex / ~/.claude 里的任何文件。
enum LocalJSONL {
    struct Entry {
        var url: URL
        var mtime: Date
        var size: Int
    }

    /// 目录内 *.jsonl 按 mtime 降序取前 limit 个（只批量预取 mtime/size，不读内容）。
    /// 不能按 2026/08/28 这类日期子目录剪枝：实测本机该目录里的会话文件 mtime 就在今天
    /// （长会话会被继续追加），剪枝会漏掉真实数据。
    static func newestFiles(in dir: URL, limit: Int) -> [Entry]? {
        // 用不抛错的那个 enumerator 重载（旧写法 try? 包住非 throwing 调用，编译器一直在 warn），
        // 并批量预取 mtime/size，避免 1500+ 次单独 stat。目录不可读时 errorHandler 返回 true 继续走完。
        guard let en = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }) else { return nil }

        var entries: [Entry] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            let size = values.fileSize ?? 0
            guard size > 0 else { continue }                      // 空文件不可能有 rate_limits
            entries.append(Entry(url: url, mtime: values.contentModificationDate ?? .distantPast, size: size))
        }
        guard !entries.isEmpty else { return nil }
        return Array(entries.sorted { $0.mtime > $1.mtime }.prefix(max(1, limit)))
    }

    /// 从 handle 当前位置读满 maxBytes。`read(upToCount:)` 不保证一次读满（实测大会话文件
    /// 偶发只回 1.2MB / 请求 8MB），必须循环补齐，否则会把文件中段当成尾部、漏掉最新上报。
    private static func readFully(_ handle: FileHandle, maxBytes: Int) -> Data? {
        var data = Data()
        data.reserveCapacity(maxBytes)
        var remaining = maxBytes
        while remaining > 0 {
            guard let chunk = try? handle.read(upToCount: remaining) else { break }
            guard !chunk.isEmpty else { break }          // EOF
            data.append(chunk)
            remaining -= chunk.count
        }
        return data.isEmpty ? nil : data
    }

    /// 只读尾部 maxBytes，并从首个完整行开始
    static func tail(of url: URL, maxBytes: Int) -> (text: String, bytes: Int)? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 else { return nil }
        let take = min(size, maxBytes)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        if size > take {
            // seek 失败会退化成「从文件头读」，那会把过期数据当最新上报，宁可放弃这个文件
            guard (try? handle.seek(toOffset: UInt64(size - take))) != nil else { return nil }
        }
        guard var data = readFully(handle, maxBytes: take) else { return nil }
        if size > take {                                           // 只读了尾部：开头是半条事件
            guard let newline = data.firstIndex(of: 0x0A) else { return nil }
            data = data.suffix(from: data.index(after: newline))
        }
        return (String(decoding: data, as: UTF8.self), data.count)
    }

    /// 只读文件头 maxBytes（取会话首条消息用）
    static func head(of url: URL, maxBytes: Int) -> (text: String, bytes: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = readFully(handle, maxBytes: maxBytes) else { return nil }
        var slice = data
        if data.count >= maxBytes, let newline = data.lastIndex(of: 0x0A) {
            slice = data.prefix(through: newline)                   // 丢掉结尾的半行
        }
        return (String(decoding: slice, as: UTF8.self), slice.count)
    }
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
        var usedPercent: Double?      // 官方未上报或格式异常时为 nil；绝不兜底成 0（详见 number(_:)）
        var windowMinutes: Int
        var resetsAt: Date
        var slot: String              // "primary" / "secondary"：同一池两档窗口时长可能相同，id 必须区分
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
        if let idToken = (auth["tokens"] as? [String: Any])?["id_token"] as? String {
            if let claims = Self.jwtPayload(idToken),
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
                                         groupID: nil))
                } else {
                    NSLog("Readers/Codex: JWT payload 解出成功但缺 chatgpt_subscription_active_until（claims 键：\(claims.keys.sorted())）")
                }
            } else {
                // 解不出 claims 时留一行日志：以前静默返回 nil，用户只看到「订阅条目凭空消失」
                let segments = idToken.split(separator: ".")
                let payloadLength = segments.count > 1 ? segments[1].count : 0
                NSLog("Readers/Codex: id_token 存在但 JWT claims 不可用（段数 \(segments.count)，payload 段长度 \(payloadLength)）")
            }
        }

        // 2) 额度窗口：官方 rate_limits 按额度池上报（通用池 limit_id="codex"，
        //    模型池带 limit_name 如 "GPT-5.3-Codex-Spark"），与官方使用页一一对应
        var pendingResets = 0
        if let pools = Self.latestRatePools(), !pools.isEmpty {
            let now = Date()
            for pool in pools {
                let poolLabel = pool.limitName.flatMap { $0.isEmpty ? nil : $0 } ?? "Codex 通用"
                for w in pool.windows {
                    // 已到点的窗口不再整块丢弃：保留条目并写明「等待新窗口上报」。
                    // 旧代码 `for w in pool.windows where w.resetsAt > now` 会在会话闲置
                    // 超过窗口长度后让额度条目凭空消失（且不会回退到次新文件里的数据）。
                    let expired = w.resetsAt <= now
                    if expired { pendingResets += 1 }
                    let note: String
                    if expired {
                        note = "官方 rate_limits · 窗口已到点，等待新窗口上报"
                    } else if let used = w.usedPercent {
                        note = String(format: "官方 rate_limits · 剩余 %.0f%%", 100 - used)
                    } else {
                        note = "官方 rate_limits · 已用未知"
                    }
                    items.append(SubItem(id: "auto:codex:\(pool.limitID):\(w.slot):\(w.windowMinutes)",
                                         name: "\(poolLabel)·\(Self.windowLabel(w.windowMinutes))",
                                         vendor: "OpenAI",
                                         kind: .window,
                                         expiresAt: w.resetsAt,
                                         repeatHours: Double(w.windowMinutes) / 60.0,
                                         source: "codex",
                                         note: note,
                                         // 到点后的已用百分比属于上一轮窗口，不能继续画在新窗口上
                                         usedPercent: expired ? nil : w.usedPercent,
                                         groupID: nil))
                }
            }
        }

        var status = "未发现到期数据"
        if !items.isEmpty {
            let prefix = plan.isEmpty ? "" : "\(plan) · "
            let tail = pendingResets > 0 ? "，\(pendingResets) 项窗口已到点等新数据" : ""
            status = "\(prefix)已读取 \(items.count) 项\(tail)"
        }
        return ReaderResult(items: items, status: status)
    }

    // MARK: 私有工具

    /// JWT 的 payload 段是 base64url（用 `-`/`_` 代替 `+`/`/`），必须先做字符替换再补 padding。
    /// 旧写法带 `.ignoreUnknownCharacters`：`Data(base64Encoded:)` 不会把 `-`/`_` 判成失败，
    /// 而是当未知字符**静默丢弃**后解出残缺乱码（实测 240 字节 payload 只解出 60 字节），
    /// 随后 JSONSerialization 才失败 → 表现为「订阅到期条目凭空消失」且毫无线索。
    /// 现在改严格解码，失败时把 payload 长度与是否含 url-safe 字符写进日志（不打印 token 内容）。
    static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let segment = String(parts[1])
        guard !segment.isEmpty else { return nil }

        var base64 = segment.replacingOccurrences(of: "-", with: "+")
                            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)

        guard let data = Data(base64Encoded: base64) else {
            NSLog("Readers/Codex: JWT payload base64 解码失败（长度 \(segment.count)，"
                  + "含 url-safe 字符 \(segment.contains("-") || segment.contains("_"))）")
            return nil
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            NSLog("Readers/Codex: JWT payload 解出 \(data.count) 字节但不是 JSON 对象"
                  + "（原始段长度 \(segment.count)，含 url-safe 字符 "
                  + "\(segment.contains("-") || segment.contains("_"))）")
            return nil
        }
        return obj
    }

    /// CLI 把数字上报得并不一致：同一 payload 里 `used_percent` 是 61.0 而
    /// `credits.balance` 实测是字符串 "60777.0562015000"。Int / Double / 字符串数字统一收口，
    /// 解不出来就是 nil —— 绝不兜底成 0（旧写法 `as? Double ?? 0` 会渲染成「剩余 100%」满格）。
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String:
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : Double(trimmed)
        default: return nil
        }
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

    // 合并最近几个会话文件（同一额度池取最新一次上报）。只读 mtime 最新的一个文件时：
    // ① 新建会话文件刚创建、还没写 rate_limits → 返回 nil，额度条目整块消失；
    // ② 会话闲置超过窗口长度 → 最新文件里的 resets_at 全部到点，也不回退次新文件。
    static let mergeFileCount = 4
    // 会话文件实测最大 650MB（本机 1524 个文件 / 14GB），rate_limits 事件在尾部持续追加、
    // 单条约 1.4KB；8MB 尾部足以覆盖最近数千条事件，不必整文件读入。
    static let tailBytes = 8 * 1024 * 1024

    /// (path, mtime, size) 指纹 → 解析结果。refreshTimer 每 60 秒跑一次，文件没变就短路。
    /// 单一后台线程串行调用（PanelUI.refreshData 有 refreshing 单飞门），仍上锁以防未来并发。
    static let cacheLock = NSLock()
    static var poolsCache: (signature: String, pools: [RatePool])?

    /// 扫描最近的 rollout 会话文件尾部，按额度池汇总官方 rate_limits
    static func latestRatePools() -> [RatePool]? {
        let sessions = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let files = LocalJSONL.newestFiles(in: sessions, limit: mergeFileCount) else { return nil }

        let signature = files.map { "\($0.url.path):\($0.mtime.timeIntervalSince1970.rounded()):\($0.size)" }
                             .joined(separator: "|")
        cacheLock.lock()
        var cached: [RatePool]?
        if poolsCache?.signature == signature { cached = poolsCache?.pools }
        cacheLock.unlock()
        if let cached { return cached.isEmpty ? nil : cached }

        // 从新到旧合并：同一 limit_id 只认第一个（最新）上报，
        // 不把不同轮次的 primary/secondary 拼进同一个池。
        var merged: [String: RatePool] = [:]
        for file in files {
            guard let text = LocalJSONL.tail(of: file.url, maxBytes: tailBytes)?.text else { continue }
            for pool in pools(in: text) where merged[pool.limitID] == nil {
                merged[pool.limitID] = pool
            }
        }

        // 通用池排最前，模型池按名称排序
        let ordered = merged.keys.sorted { a, b in
            if (a == "codex") != (b == "codex") { return a == "codex" }
            return a < b
        }
        let result = ordered.compactMap { merged[$0] }
        cacheLock.lock()
        poolsCache = (signature, result)
        cacheLock.unlock()
        return result.isEmpty ? nil : result
    }

    /// 解析一段（文件尾部的）jsonl 文本，返回其中出现的额度池；同一池取本段最后一条事件。
    ///
    /// 旧写法是字符串定位 `"rate_limits":` 再取下一个 `{` 交给 balancedJSON，两个坑：
    /// ① `"rate_limits":null` 的行会顺延去抓同行后面的无关对象（本机当前键序里 rate_limits 是
    ///    payload 最后一个字段，所以实测表现为「整行被跳过」；一旦键序变化就是错位条目）；
    /// ② 命中在字符串值内部的同名文本上，取到的对象再被 `limit_id ?? "codex"` 兜底成通用池。
    /// 现在整行 JSON 解析 + 按 key 路径取值：null / NSNull 解不出字典，字符串值也不可能是字段。
    static func pools(in text: String) -> [RatePool] {
        var found: [String: RatePool] = [:]
        var order: [String] = []
        text.enumerateLines { line, _ in
            guard line.contains("\"rate_limits\"") else { return }   // 绝大多数行是 token 明细，先跳过
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let limits = Self.rateLimits(in: obj) else { return }

            var windows: [RateWindow] = []
            for slot in ["primary", "secondary"] {
                // isFinite 不能省：Int(Double.infinity) 会直接崩，而字段来自外部 JSON
                guard let w = limits[slot] as? [String: Any],
                      let resets = Self.number(w["resets_at"]), resets > 0, resets.isFinite else { continue }
                guard let minutesValue = Self.number(w["window_minutes"]), minutesValue > 0, minutesValue.isFinite else { continue }
                let used = Self.number(w["used_percent"]).flatMap { $0.isFinite ? $0 : nil }
                windows.append(RateWindow(usedPercent: used,
                                          windowMinutes: Int(minutesValue),
                                          resetsAt: Date(timeIntervalSince1970: resets),
                                          slot: slot))
            }
            guard !windows.isEmpty else { return }
            let limitID = (limits["limit_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "codex"
            if found[limitID] == nil { order.append(limitID) }
            found[limitID] = RatePool(limitID: limitID, limitName: limits["limit_name"] as? String,
                                      windows: windows)
        }
        return order.compactMap { found[$0] }
    }

    /// rate_limits 挂在事件的 payload 下（本机全部命中都是 payload.rate_limits），兼容顶层写法。
    /// `"rate_limits":null` 与 `"secondary":null` 都是 NSNull，字典转换自然失败 → 不参与解析。
    static func rateLimits(in obj: [String: Any]) -> [String: Any]? {
        if let direct = obj["rate_limits"] as? [String: Any] { return direct }
        if let payload = obj["payload"] as? [String: Any],
           let nested = payload["rate_limits"] as? [String: Any] { return nested }
        return nil
    }
}

// MARK: - Claude Code（本地会话估算 5h 窗口）

final class ClaudeReader: SourceReader {
    let name = "Claude"
    static let windowSeconds: TimeInterval = 5 * 3600
    // 只需在尾部覆盖 5 小时的活动区间；Claude 会话文件实测单文件最大约 800KB，
    // 4MB 上限对更大的文件也只是「看不到更早的消息」，方向是保守的（见 windowStart）。
    static let tailBytes = 4 * 1024 * 1024
    static let headBytes = 64 * 1024
    static let scanFileLimit = 200

    func read() -> ReaderResult {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeDir = home.appendingPathComponent(".claude")
        guard FileManager.default.fileExists(atPath: claudeDir.path) else {
            return ReaderResult(items: [], status: "未安装 / 未检测到（~/.claude）")
        }

        // Claude Code 不落盘官方重置时间。窗口的本地估算语义：
        //   最近一次活动 = 会话里最后一条消息时间；
        //   窗口起点 = 从最近一次活动往前数、仍落在 5 小时之内的最早一条消息。
        // 旧实现把「会话首条消息」当窗口起点：8 小时前开的会话哪怕刚刚还在写，也会被
        // `now - first < 5h` 整体判成「最近 5 小时无活动」；反过来刚开的会话又会给出
        // 「第一条消息 + 5h」这种假重置点。注意：这始终是**本地估算**，不是官方上报。
        let now = Date()
        let projects = claudeDir.appendingPathComponent("projects", isDirectory: true)
        guard let files = LocalJSONL.newestFiles(in: projects, limit: Self.scanFileLimit) else {
            return ReaderResult(items: [], status: "已安装，暂无会话数据")
        }

        var best: (start: Date, last: Date, url: URL)?
        for file in files {
            // mtime 超过 5 小时的会话不可能落在当前窗口，连内容都不用读
            guard now.timeIntervalSince(file.mtime) < Self.windowSeconds else { continue }
            guard let text = LocalJSONL.tail(of: file.url, maxBytes: Self.tailBytes)?.text else { continue }
            let stamps = Self.timestamps(in: text)
            guard let last = stamps.max(), now.timeIntervalSince(last) < Self.windowSeconds else { continue }
            guard let start = Self.windowStart(timestamps: stamps, last: last) else { continue }
            if let current = best {
                if start < current.start { best = (start, last, file.url) }
            } else {
                best = (start, last, file.url)
            }
        }

        guard let hit = best else {
            return ReaderResult(items: [], status: "已安装，最近 5 小时无活动")
        }
        let reset = hit.start.addingTimeInterval(Self.windowSeconds)
        guard reset > now else { return ReaderResult(items: [], status: "窗口已重置，待新活动") }

        // 起点更实的情形：本会话首条消息（只读文件头 64KB）本身就落在窗口内。
        var note = "本地估算（非官方上报）：窗口起点＝最近 5 小时内可见的首条消息"
        if let first = Self.firstTimestamp(of: hit.url, maxBytes: Self.headBytes),
           first >= hit.last.addingTimeInterval(-Self.windowSeconds) {
            note = "本地估算（非官方上报）：窗口起点＝本会话首条消息"
        }

        let item = SubItem(id: "auto:claude:window5h",
                           name: "Claude 5小时窗口(估算)",
                           vendor: "Anthropic",
                           kind: .window,
                           expiresAt: reset,
                           repeatHours: 5,
                           source: "claude",
                           note: note)
        return ReaderResult(items: [item], status: "已估算当前窗口")
    }

    /// 窗口起点：最近一次活动往前、仍在 5 小时之内的最早一条消息。
    /// 尾部只读了 tailBytes，若它没覆盖到 last−5h 这条边界，看不到的更早消息会让起点偏晚、
    /// 重置点偏乐观 —— 所以条目标题与 note 都写明「估算/非官方上报」，不当作官方数据展示。
    static func windowStart(timestamps: [Date], last: Date) -> Date? {
        let lower = last.addingTimeInterval(-windowSeconds)
        var start: Date?
        for t in timestamps where t >= lower && t <= last {
            if let current = start {
                if t < current { start = t }
            } else {
                start = t
            }
        }
        return start
    }

    /// 一段会话文本里所有可解析的消息时间（跳过不含 timestamp 的行再解析，省掉大量 JSON 解析）
    static func timestamps(in text: String) -> [Date] {
        var out: [Date] = []
        text.enumerateLines { line, _ in
            guard line.contains("\"timestamp\"") else { return }
            if let d = timestamp(of: line) { out.append(d) }
        }
        return out
    }

    static func timestamp(of line: String) -> Date? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let ts = obj["timestamp"] as? String else { return nil }
        return CodexReader.parseISO(ts)
    }

    /// 会话首条消息时间：只读文件头（旧版整文件读入，大会话会白烧几百 MB 内存）
    static func firstTimestamp(of url: URL, maxBytes: Int = headBytes) -> Date? {
        guard let text = LocalJSONL.head(of: url, maxBytes: maxBytes)?.text else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let d = timestamp(of: String(line)) { return d }
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

    /// 该字段来自外部 JSON，可能是 token 片段而不是邮箱，两种兜底都不能原样输出整串：
    /// ① 没有 `@` → 只留前 3 个字符；② 本地部分不足 2 字符 → 只留首字符。
    static func maskEmail(_ e: String) -> String {
        guard let at = e.firstIndex(of: "@") else {
            return "\(e.prefix(3))***"
        }
        let local = String(e[e.startIndex..<at])
        let domain = String(e[at...])
        let head = local.count < 2 ? local.prefix(1) : local.prefix(2)
        return "\(head)***\(domain)"
    }
}
