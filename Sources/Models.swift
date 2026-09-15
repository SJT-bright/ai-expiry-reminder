import Foundation

// MARK: - 数据模型

enum ItemKind: String, Codable {
    case subscription   // 订阅到期（一次性，如 ChatGPT Pro 月付、重置卡）
    case window         // 周期额度窗口（到期后自动滚动，如 Codex 5小时窗口）
}

/// 额度重置模型：rolling=自锚点起按 repeatHours 滚动（Codex/GLM/Grok 类）；
/// calendarMonth=每月固定 param 日 00:00 本地重置（如每月17号，15号买入则15→17为首段）；
/// calendarWeek=每周固定 param 星期几 00:00 本地重置（如通义千问每周一）；
/// anchorMonth=每月「订阅日」00:00 重置（千问月额度，param=订阅日的几号）
enum ResetRule: String, Codable {
    case rolling
    case calendarMonth
    case calendarWeek
    case anchorMonth
}

struct SubItem: Codable, Equatable {
    var id: String
    var name: String
    var vendor: String
    var kind: ItemKind
    var expiresAt: Date
    var repeatHours: Double?        // kind == .window 时生效
    var source: String              // "manual" / "codex" / "claude" / "grok" / ...
    var note: String
    var alertBeforeMinutes: Double
    var usedPercent: Double?        // 官方已用百分比（有则显示进度条），手动条目为 nil
    var groupID: String?            // 按周划分生成的同组条目共享一个组 ID
    var resetRule: ResetRule?       // nil = 滚动（repeatHours）；否则为日历锚定重置
    var resetParam: Int?            // calendarMonth: 几号(1-31)；calendarWeek/anchorMonth: 星期几(1=周一…7=周日)

    /// 仅识别按周拆分生成的订阅，避免把派生重置窗口当作下一周。
    var weekIndex: Int? {
        guard kind == .subscription, groupID != nil,
              let range = name.range(of: "·第[0-9]+/[0-9]+周$", options: .regularExpression) else { return nil }
        return Int(name[range].dropFirst(2).split(separator: "/")[0])
    }

    var isAuto: Bool { source != "manual" }

    /// 是否为「额度重置」类窗口：官方额度窗口或周额度重置伴生窗口。
    /// 手动创建的通用周期窗口（裸 UUID id）可能承载续费日等非重置语义，不称「重置」。
    var isQuotaResetWindow: Bool {
        kind == .window && (isAuto || id.hasPrefix("qreset:"))
    }

    /// 日历类规则：now 之后的下一次重置（本地时区 00:00；小月钳到月末；离线跨周期不累积）
    func nextCalendarReset(after now: Date, calendar: Calendar = .current) -> Date? {
        guard resetRule == .calendarMonth || resetRule == .calendarWeek || resetRule == .anchorMonth else { return nil }
        func clampDay(_ day: Int, in date: Date) -> Date? {
            let days = calendar.range(of: .day, in: .month, for: date)!.count
            var comps = calendar.dateComponents([.year, .month], from: date)
            comps.day = min(day, days)
            comps.hour = 0; comps.minute = 0; comps.second = 0
            return calendar.date(from: comps)
        }
        switch resetRule {
        case .calendarMonth, .anchorMonth:
            guard let day = resetParam, (1...31).contains(day) else { return nil }
            var candidate = clampDay(day, in: now) ?? now
            while candidate <= now {   // 本月节点已过 → 下月（再钳制）
                let next = calendar.date(byAdding: .month, value: 1, to: candidate) ?? candidate
                candidate = clampDay(day, in: next) ?? next
            }
            return candidate
        case .calendarWeek:
            guard let param = resetParam, (1...7).contains(param) else { return nil }
            let targetWeekday = param == 7 ? 1 : param + 1   // 参数 1=周一…7=周日 → Calendar 1=周日
            let weekday = calendar.component(.weekday, from: now)
            var comps = calendar.dateComponents([.year, .month, .day], from: now)
            var shift = (targetWeekday - weekday + 7) % 7
            if shift == 0 { shift = 7 }                      // 今天即是该星期几 → 下周（00:00 已过即失去意义）
            comps.day! += shift
            comps.hour = 0; comps.minute = 0; comps.second = 0
            return calendar.date(from: comps)
        default:
            return nil
        }
    }

    /// 日历类规则：now 之前的上一次重置（额度窗口起点，用于 ⚡ 消耗节奏）
    func previousCalendarReset(before now: Date, calendar: Calendar = .current) -> Date? {
        guard let next = nextCalendarReset(after: now, calendar: calendar) else { return nil }
        switch resetRule {
        case .calendarMonth, .anchorMonth:
            return calendar.date(byAdding: .month, value: -1, to: next)
        case .calendarWeek:
            return calendar.date(byAdding: .day, value: -7, to: next)
        default:
            return nil
        }
    }

    static func manualDefault(name: String = "", vendor: String = "") -> SubItem {
        SubItem(id: UUID().uuidString,
                name: name,
                vendor: vendor,
                kind: .subscription,
                expiresAt: Date().addingTimeInterval(3600 * 24 * 30),
                repeatHours: nil,
                source: "manual",
                note: "",
                alertBeforeMinutes: 60,
                usedPercent: nil,
                groupID: nil)
    }

    /// 按周划分额度：以到期日为锚点倒推，每 7 天一个窗口，
    /// 不足 7 天的零头作为第一个窗口（例：还剩 10 天 → 提醒点在 3 天后和 10 天后）。
    /// 返回的条目共享 groupID。
    func splitWeekly(from start: Date = Date()) -> [SubItem] {
        let week: TimeInterval = 7 * 86400
        let total = expiresAt.timeIntervalSince(start)
        guard total > week else { return [self] }   // 不足一周无需划分
        let n = Int(ceil(total / week))
        let gid = UUID().uuidString
        return (1...n).map { k in
            var v = self
            v.id = UUID().uuidString
            v.groupID = gid
            v.kind = .subscription
            v.repeatHours = nil
            v.usedPercent = nil
            v.name = "\(name)·第\(k)/\(n)周"
            v.note = "按周自动划分（自到期日倒推，每周7天）"
            // 第 k 条边界 = 到期日 − 7天×(n−k)：最后一刀就是到期日本身
            if k < n { v.expiresAt = expiresAt.addingTimeInterval(-week * Double(n - k)) }
            return v
        }
    }
}

// 自定义解码放在扩展里：避免吞掉结构体的 memberwise 构造器
extension SubItem {
    private enum CodingKeys: String, CodingKey {
        case id, name, vendor, kind, expiresAt, repeatHours, source, note
        case alertBeforeMinutes, usedPercent, groupID, resetRule, resetParam
    }

    /// 旧数据（state.json 迁移源）无 reset 字段时按 nil 容错
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        vendor = try c.decode(String.self, forKey: .vendor)
        kind = try c.decode(ItemKind.self, forKey: .kind)
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
        repeatHours = try c.decodeIfPresent(Double.self, forKey: .repeatHours)
        source = try c.decode(String.self, forKey: .source)
        note = try c.decode(String.self, forKey: .note)
        alertBeforeMinutes = try c.decode(Double.self, forKey: .alertBeforeMinutes)
        usedPercent = try c.decodeIfPresent(Double.self, forKey: .usedPercent)
        groupID = try c.decodeIfPresent(String.self, forKey: .groupID)
        resetRule = try c.decodeIfPresent(ResetRule.self, forKey: .resetRule)
        resetParam = try c.decodeIfPresent(Int.self, forKey: .resetParam)
    }
}

// MARK: - 自动收起抑制器（说明弹窗/编辑期间抑制面板自动收起）

/// 纯逻辑状态机：begin 抑制 → end 按光标位置决定是否立即恢复定时。
/// 坐标判定由调用方（PanelController，经 NSWindow.convertFromScreen 系统转换）完成。
struct AutoCollapseSuppressor: Equatable {
    private(set) var isSuppressed = false

    mutating func begin() { isSuppressed = true }

    /// 结束抑制。光标仍在面板内：返回 false（鼠标移出面板时由 mouseExited 自然重挂定时器）；
    /// 光标已离开面板：返回 true（立即恢复 8 秒自动收起节奏）。
    mutating func end(cursorInsidePanel: Bool) -> Bool {
        isSuppressed = false
        return !cursorInsidePanel
    }

    /// scheduleAutoCollapse 入口检查：抑制期间不启动定时器
    var shouldSchedule: Bool { !isSuppressed }
}

/// 设置（轻量 KV，走 state.json）；记录类数据全部在 SQLite
struct AppState: Codable {
    var notifiedKeys: [String] = []
    var feishuWebhook: String = ""
    var panelCollapsed: Bool = true
    var launchAtLogin: Bool = false
    var dismissedAuto: [String] = []   // 被用户隐藏的官方条目 id（⟳ 刷新可恢复）
}

/// 手动条目写入结果：区分「完全失败」「已保存但关联同步失败」「全部成功」
enum ManualWriteResult: Equatable {
    case success                                   // 父与关联全部写成功
    case parentFailed                              // 一条都未写入（表单应保留，用户可整体重试）
    case savedWithAlignFailure(failures: [String]) // 父已写入；failures = 未能同步的关联写（"action:id" 证据）
    case partialSaved(written: Int, failed: Int)   // 批量：部分成员已写入

    /// 父数据是否已落库（决定表单能否关闭）
    var saved: Bool {
        switch self {
        case .success, .savedWithAlignFailure, .partialSaved: return true
        case .parentFailed: return false
        }
    }
}

// MARK: - 存储（数据库 + 设置）

final class Store {
    static let shared = Store()

    let db: Database
    let dir: URL
    private let settingsFileURL: URL
    private let queue = DispatchQueue(label: "store.io")

    /// 设置
    var state = AppState()
    /// 手动条目（内存缓存，真身在 SQLite）
    private(set) var manualItems: [SubItem] = []

    /// environment 参数供测试注入隔离/故障数据目录（如只读目录构造写失败）
    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let base: URL
        if let override = environment["AR_DATA_DIR"] {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        }
        dir = base.appendingPathComponent("AI到期提醒", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settingsFileURL = dir.appendingPathComponent("state.json")
        db = Database(dir: dir)

        // 设置加载
        if let data = try? Data(contentsOf: settingsFileURL),
           let legacy = try? JSONDecoder().decode(AppState.self, from: data) {
            state = legacy
        }

        migrateLegacyManualItems()
        manualItems = db.loadItems()
        rollManualWindows()
    }

    /// 旧版 state.json 里的 manualItems 迁移进数据库（一次性，幂等）
    private func migrateLegacyManualItems() {
        guard let data = try? Data(contentsOf: settingsFileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let legacy = obj["manualItems"] as? [[String: Any]], !legacy.isEmpty else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var imported = 0
        for row in legacy {
            guard let d = try? JSONSerialization.data(withJSONObject: row),
                  var item = try? dec.decode(SubItem.self, from: d) else { continue }
            if item.id.hasPrefix("demo:") { continue }   // 测试数据不入库
            if db.upsert(item, action: "import") { imported += 1 }
        }
        NSLog("AR: 已迁移 \(imported) 条旧记录到 SQLite")
        save()   // 重写 state.json，去掉 manualItems 键
    }

    /// 保存设置（记录类数据在数据库，不经此路径）。写盘结果经 onSettingsWriteResult（主线程）反馈
    func save() {
        state.notifiedKeys = Array(state.notifiedKeys.suffix(300))
        queue.async { [weak self, state, settingsFileURL] in
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            var ok = false
            if let data = try? enc.encode(state) {
                do {
                    try data.write(to: settingsFileURL, options: .atomic)
                    ok = true
                } catch {
                    NSLog("AR: state.json 写盘失败: \(error.localizedDescription)")
                }
            } else {
                NSLog("AR: state.json 编码失败，设置未保存")
            }
            guard let self else { return }
            self.settingsWriteLock.lock()
            let changed = self.lastSettingsWriteOK != ok
            self.lastSettingsWriteOK = ok
            self.settingsWriteLock.unlock()
            // 仅状态变化或失败时通知；主线程更新 UI
            if changed || !ok {
                DispatchQueue.main.async { self.onSettingsWriteResult?(ok) }
            }
        }
    }

    // MARK: 手动条目（数据库读写穿透）

    /// 测试注入：按 (条目, action) 模拟写入结果；返回 nil = 走真实写入。
    /// action 取值：add / update / add_week / align_reset / align_week
    var upsertInjection: ((_ item: SubItem, _ action: String) -> Bool?)?

    /// 最近一次父条目写成功但关联对齐写失败的证据（"action:id" 列表）
    private(set) var lastAlignmentFailures: [String] = []

    private let settingsWriteLock = NSLock()
    /// 最近一次设置写盘结果：nil = 尚未写入。线程安全；UI 更新须经 onSettingsWriteResult（主线程）
    private(set) var lastSettingsWriteOK: Bool?
    /// 设置写盘结果回调（主线程调用）；成功也会回调以清除旧失败提示
    var onSettingsWriteResult: ((Bool) -> Void)?

    /// 写入失败返回三态结果，调用方据此区分反馈（父失败/部分失败/成功）
    @discardableResult
    func upsertManual(_ item: SubItem) -> ManualWriteResult {
        let previous = manualItems.first { $0.id == item.id }
        let action = previous == nil ? "add" : "update"
        guard write(item, action: action) else { return .parentFailed }
        var failures: [String] = []
        if let previous, previous.expiresAt != item.expiresAt,
           var reset = manualItems.first(where: { $0.id == "qreset:" + item.id }) {
            reset.expiresAt = reset.expiresAt.addingTimeInterval(item.expiresAt.timeIntervalSince(previous.expiresAt))
            if !write(reset, action: "align_reset") { failures.append("align_reset:\(reset.id)") }
        }
        // 已拆分的周提醒在修改某一周后，后续周沿这一次到期时间排列。
        if let previous, previous.expiresAt != item.expiresAt,
           let group = item.groupID, let index = item.weekIndex {
            for var sibling in manualItems where sibling.groupID == group {
                guard let nextIndex = sibling.weekIndex, nextIndex > index else { continue }
                let oldExpiry = sibling.expiresAt
                sibling.expiresAt = item.expiresAt.addingTimeInterval(Double(nextIndex - index) * 7 * 86400)
                if !write(sibling, action: "align_week") {
                    failures.append("align_week:\(sibling.id)")
                    continue   // 兄弟成员本身写失败，其伴生窗口不再平移
                }
                if var reset = manualItems.first(where: { $0.id == "qreset:" + sibling.id }) {
                    reset.expiresAt = reset.expiresAt.addingTimeInterval(sibling.expiresAt.timeIntervalSince(oldExpiry))
                    if !write(reset, action: "align_week") { failures.append("align_week:\(reset.id)") }
                }
            }
        }
        manualItems = db.loadItems()
        lastAlignmentFailures = failures
        return failures.isEmpty ? .success : .savedWithAlignFailure(failures: failures)
    }

    /// 批量写入：区分全部成功 / 全部未写 / 部分已写（失败成员可按同一 id 重试补齐）
    @discardableResult
    func upsertManual(_ items: [SubItem]) -> ManualWriteResult {
        var written = 0
        var failed = 0
        for item in items {
            if write(item, action: item.groupID != nil ? "add_week" : "add") { written += 1 } else { failed += 1 }
        }
        manualItems = db.loadItems()
        if failed == 0 { return .success }
        return written > 0 ? .partialSaved(written: written, failed: failed) : .parentFailed
    }

    /// 实际写入（测试注入缝）：优先走 upsertInjection
    private func write(_ item: SubItem, action: String) -> Bool {
        if let injected = upsertInjection?(item, action) { return injected }
        return db.upsert(item, action: action)
    }

    /// 删除失败返回 false；调用方据此向用户反馈
    @discardableResult
    func deleteManual(id: String) -> Bool {
        let ok = db.delete(id: id)
        manualItems = db.loadItems()
        return ok
    }

    /// 删除手动条目及其派生的周额度重置窗口（qreset: 前缀）
    func deleteManualWithDerived(_ id: String) {
        db.delete(id: id)
        db.delete(id: "qreset:" + id)
        manualItems = db.loadItems()
    }

    /// 批量删除手动条目及其派生的周额度重置窗口（清理过期路径使用）
    func deleteManualsWithDerived(_ ids: [String]) {
        for id in ids {
            db.delete(id: id)
            db.delete(id: "qreset:" + id)
        }
        manualItems = db.loadItems()
    }

    /// 删除整组（按周划分），返回删除条数
    @discardableResult
    func deleteGroup(_ groupID: String) -> Int {
        let n = db.deleteGroup(groupID)
        manualItems = db.loadItems()
        return n
    }

    /// 过期超过 24 小时的手动条目
    func expiredManualItems(olderThan hours: Double = 24) -> [SubItem] {
        let cutoff = Date().addingTimeInterval(-hours * 3600)
        return manualItems.filter { $0.expiresAt < cutoff }
    }

    @discardableResult
    func deleteManuals(ids: [String]) -> Int {
        ids.forEach { db.delete(id: $0, action: "clean_expired") }
        manualItems = db.loadItems()
        return ids.count
    }

    /// 周期窗口到期后推进到下一次（写回数据库）。
    /// rolling：按 repeatHours 整倍数前滚（相位保持）；
    /// 日历模型：跳到下一个未来节点（离线跨周期不累积——错过的日历节点不会补）
    func rollManualWindows(now: Date = Date()) {
        var rolled = false
        for i in manualItems.indices {
            guard manualItems[i].kind == .window else { continue }
            var next: Date?
            switch manualItems[i].resetRule {
            case .calendarMonth, .calendarWeek, .anchorMonth:
                guard manualItems[i].expiresAt <= now else { continue }
                next = manualItems[i].nextCalendarReset(after: now)
            default:
                guard let h = manualItems[i].repeatHours, h > 0 else { continue }
                var t = manualItems[i].expiresAt
                var guardCounter = 0
                while t <= now && guardCounter < 100_000 {
                    t = t.addingTimeInterval(h * 3600)
                    guardCounter += 1
                }
                next = t
            }
            guard let next, next != manualItems[i].expiresAt else { continue }
            manualItems[i].expiresAt = next
            db.upsert(manualItems[i], action: "roll")
            rolled = true
        }
        if rolled { manualItems.sort { $0.expiresAt < $1.expiresAt } }
    }

    /// 操作历史（最近 N 条，倒序）
    func recentHistory(limit: Int = 50) -> [(date: Date, action: String, summary: String)] {
        db.recentHistory(limit: limit)
    }
}

// MARK: - 时间格式化

enum Fmt {
    static func countdown(until: Date, now: Date = Date()) -> String {
        let sec = until.timeIntervalSince(now)
        if sec <= -86400 { return "已过期 \(-Int(sec) / 86400)天+" }
        if sec <= 0 { return "已过期\(-Int(sec) / 60)分" }
        let s = Int(sec)
        if s >= 172800 { return "\(s / 86400)天\((s % 86400) / 3600)小时" }
        if s >= 3600 { return "\(s / 3600)小时\((s % 3600) / 60)分" }
        if s >= 60 { return "\(s / 60)分\((s % 60))秒" }
        return "\(s)秒"
    }

    /// 紧凑格式：药丸 / 表格用
    static func countdownShort(until: Date, now: Date = Date()) -> String {
        let sec = until.timeIntervalSince(now)
        if sec <= 0 { return "已过期" }
        let s = Int(sec)
        if s >= 86400 * 10 { return "\(s / 86400)天" }
        if s >= 86400 { return "\(s / 86400)天\((s % 86400) / 3600)时" }
        if s >= 3600 { return "\(s / 3600)时\((s % 3600) / 60)分" }
        if s >= 60 { return "\(s / 60)分" }
        return "\(s)秒"
    }

    static func absTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = .current
        return f.string(from: d)
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = .current
        return f.string(from: d)
    }
}
