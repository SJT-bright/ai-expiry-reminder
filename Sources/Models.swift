import Foundation

// MARK: - 数据模型

enum ItemKind: String, Codable {
    case subscription   // 订阅到期（一次性，如 ChatGPT Pro 月付、重置卡）
    case window         // 周期额度窗口（到期后自动滚动，如 Codex 5小时窗口）
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

    var isAuto: Bool { source != "manual" }

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

/// 设置（轻量 KV，走 state.json）；记录类数据全部在 SQLite
struct AppState: Codable {
    var notifiedKeys: [String] = []
    var feishuWebhook: String = ""
    var panelCollapsed: Bool = true
    var launchAtLogin: Bool = false
    var dismissedAuto: [String] = []   // 被用户隐藏的官方条目 id（⟳ 刷新可恢复）
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

    init() {
        let base: URL
        if let override = ProcessInfo.processInfo.environment["AR_DATA_DIR"] {
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

    /// 保存设置（记录类数据在数据库，不经此路径）
    func save() {
        state.notifiedKeys = Array(state.notifiedKeys.suffix(300))
        queue.async { [state, settingsFileURL] in
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(state) {
                try? data.write(to: settingsFileURL, options: .atomic)
            }
        }
    }

    // MARK: 手动条目（数据库读写穿透）

    func upsertManual(_ item: SubItem) {
        let action = manualItems.contains { $0.id == item.id } ? "update" : "add"
        db.upsert(item, action: action)
        manualItems = db.loadItems()
    }

    func upsertManual(_ items: [SubItem]) {
        items.forEach { db.upsert($0, action: $0.groupID != nil ? "add_week" : "add") }
        manualItems = db.loadItems()
    }

    func deleteManual(id: String) {
        db.delete(id: id)
        manualItems = db.loadItems()
    }

    /// 删除手动条目及其派生的周额度重置窗口（qreset: 前缀）
    func deleteManualWithDerived(_ id: String) {
        db.delete(id: id)
        db.delete(id: "qreset:" + id)
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

    /// 手动的周期窗口到期后自动滚动到下一次（写回数据库）
    func rollManualWindows(now: Date = Date()) {
        var rolled = false
        for i in manualItems.indices {
            guard manualItems[i].kind == .window,
                  let h = manualItems[i].repeatHours, h > 0 else { continue }
            var t = manualItems[i].expiresAt
            var guardCounter = 0
            while t <= now && guardCounter < 100_000 {
                t = t.addingTimeInterval(h * 3600)
                guardCounter += 1
            }
            if t != manualItems[i].expiresAt {
                manualItems[i].expiresAt = t
                db.upsert(manualItems[i], action: "roll")
                rolled = true
            }
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
