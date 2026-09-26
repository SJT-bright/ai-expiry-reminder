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
    var usedPercent: Double?        // 官方已用百分比（有则显示进度条），手动条目为 nil
    var groupID: String?            // 按周划分生成的同组条目共享一个组 ID
    var resetRule: ResetRule?       // nil = 滚动（repeatHours）；否则为日历锚定重置
    var resetParam: Int?            // calendarMonth: 几号(1-31)；calendarWeek/anchorMonth: 星期几(1=周一…7=周日)
    // ↓ 新字段一律追加在末尾（memberwise 构造器参数顺序被 PanelUI/TestRender 依赖）
    var purchaseAt: Date?           // 购买时间：智能推断的输入；旧数据为 nil
    var archivedAt: Date?           // 归档时间：nil = 未归档
    var updatedAt: Date?            // 只读，来自 DB updated_at（JSON 解码 decodeIfPresent 容错）

    /// 仅识别按周拆分生成的订阅，避免把派生重置窗口当作下一周。
    var weekIndex: Int? {
        guard kind == .subscription, groupID != nil,
              let range = name.range(of: "·第[0-9]+/[0-9]+周$", options: .regularExpression) else { return nil }
        return Int(name[range].dropFirst(2).split(separator: "/")[0])
    }

    var isAuto: Bool { source != "manual" }

    /// 是否已归档（过期后自动/手动归档；归档条目在列表沉底，超过保留期后清除）
    var isArchived: Bool { archivedAt != nil }

    /// 周期重置伴生窗口的确定性 id：跟随父订阅，编辑时反查、保存时幂等更新
    static func quotaResetId(for parentID: String) -> String { "qreset:" + parentID }

    /// 展示排序：未归档在前按到期时间升序（最先到期的最抢眼）；
    /// 已归档在后按到期时间降序（刚过期的排前面）。
    static func displaySorted(_ items: [SubItem], now: Date = Date()) -> [SubItem] {
        let archived = items.filter { $0.isArchived }
        let live = items.filter { !$0.isArchived }
        return live.sorted { $0.expiresAt < $1.expiresAt }
             + archived.sorted { $0.expiresAt > $1.expiresAt }
    }

    /// 是否为「额度重置」类窗口：官方额度窗口或周额度重置伴生窗口。
    /// 手动创建的通用周期窗口（裸 UUID id）可能承载续费日等非重置语义，不称「重置」。
    var isQuotaResetWindow: Bool {
        kind == .window && (isAuto || id.hasPrefix("qreset:"))
    }

    /// 常数时间跳过离线周期，保持锚点；异常参数不参与调度。
    static func nextRollingReset(anchor: Date, hours: Double, now: Date) -> Date? {
        let interval = hours * 3600
        let elapsed = now.timeIntervalSince(anchor)
        guard hours.isFinite, hours > 0, interval.isFinite,
              anchor.timeIntervalSince1970.isFinite, elapsed.isFinite else { return nil }
        if anchor > now { return anchor }
        let next = anchor.addingTimeInterval((floor(elapsed / interval) + 1) * interval)
        return next.timeIntervalSince1970.isFinite && next > now ? next : nil
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

    /// 日历类规则：now 之前的上一次重置（额度窗口起点，用于 ⚡ 消耗节奏）。
    /// 月末钳制回退：从本月 param 日重新构造，若尚未到来则取上月的钳制日（2/15 回退 31 号 → 1/31 而非 1/28）
    func previousCalendarReset(before now: Date, calendar: Calendar = .current) -> Date? {
        guard nextCalendarReset(after: now, calendar: calendar) != nil else { return nil }
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
            if let thisMonth = clampDay(day, in: now), thisMonth <= now { return thisMonth }
            let prevMonth = calendar.date(byAdding: .month, value: -1, to: now) ?? now
            return clampDay(day, in: prevMonth)
        case .calendarWeek:
            guard let next = nextCalendarReset(after: now, calendar: calendar) else { return nil }
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
        case usedPercent, groupID, resetRule, resetParam
        case purchaseAt, archivedAt, updatedAt
    }

    /// 旧数据（state.json 迁移源 / 旧版 SQLite）缺少新字段时按 nil 容错
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
        usedPercent = try c.decodeIfPresent(Double.self, forKey: .usedPercent)
        groupID = try c.decodeIfPresent(String.self, forKey: .groupID)
        resetRule = try c.decodeIfPresent(ResetRule.self, forKey: .resetRule)
        resetParam = try c.decodeIfPresent(Int.self, forKey: .resetParam)
        purchaseAt = try c.decodeIfPresent(Date.self, forKey: .purchaseAt)
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

// MARK: - 重置模型推断（降低选择成本）
// 输入：购买时间 / 到期时间 / 最近一次重置时间 → 推断「官方固定日历重置」还是「购买锚定滚动」等。
// 判定依据（公开规则调研见 RESEARCH.md）：
// - 重置时刻与购买时刻完全同刻、且都在 7 天网格上 → 自购买滚动的周额度
// - 最近重置的「几号」== 购买日的「几号」→ 订阅日锚定月（anchorMonth）
// - 最近重置为 00:00 整点 → 官方固定日历（星期几 → calendarWeek；几号 → calendarMonth）
// - 其余 → 按最近重置时间滚动（保底）

/// 推断结果：规则 + 参数 + 锚点 + 人话解释 + 周期小时数（rolling 档才有）
struct ResetInferenceResult: Equatable {
    let rule: ResetRule
    let param: Int?
    let anchor: Date
    let explain: String
    var repeatHours: Double? = nil   // 推断出的周期小时数；日历模型为 nil
}

/// 周期档位（小时）：5h / 1天 / 1周 / 30天 / 31天 / 90天 / 180天 / 365天
enum ResetInference {
    /// 从购买→到期间隔推周期小时数：命中已知档位（±6h 容差）则返回档位值，否则 nil
    static func inferPeriodHours(purchase: Date, expiry: Date) -> Double? {
        let hours = expiry.timeIntervalSince(purchase) / 3600
        guard hours > 0 else { return nil }
        let tiers: [Double] = [5, 24, 168, 720, 744, 2160, 4320, 8760]
        return tiers.first { abs(hours - $0) <= 6 }
    }

    /// 全量推断（保存时自动补全重置节奏）：
    /// 优先级 = 历史继承（同供应商最近窗口） → 厂商知识库 → 购买→到期间隔推断 → 保底 rolling(7天)
    static func infer(name: String, vendor: String, expiresAt: Date, purchaseAt: Date?,
                      history: (rule: ResetRule?, param: Int?, repeatHours: Double?)?,
                      now: Date = Date()) -> ResetInferenceResult {
        // 1) 历史继承：同供应商最近一条带重置模型的窗口
        if let h = history, h.rule != nil || h.repeatHours != nil {
            if let rule = h.rule, rule != .rolling {
                return .init(rule: rule, param: h.param, anchor: expiresAt,
                             explain: "沿用同供应商历史重置节奏", repeatHours: h.repeatHours)
            }
            let hours = h.repeatHours ?? 168
            return .init(rule: .rolling, param: daysParam(forHours: hours), anchor: expiresAt,
                         explain: "沿用同供应商历史重置节奏", repeatHours: hours)
        }
        // 2) 厂商知识库：公开调研的可信规则（宁缺毋滥）
        if let cand = VendorResetKnowledge.bestCandidate(for: vendor) {
            let anchor = expiresAt
            return .init(rule: cand.rule, param: cand.param, anchor: anchor,
                         explain: cand.explain, repeatHours: cand.repeatHours)
        }
        // 3) 购买→到期间隔命中已知档位 → 按该周期自购买滚动
        if let p = purchaseAt, let hours = inferPeriodHours(purchase: p, expiry: expiresAt) {
            return .init(rule: .rolling, param: daysParam(forHours: hours), anchor: now,
                         explain: "按购买→到期间隔约 \(Int(hours)) 小时滚动", repeatHours: hours)
        }
        // 4) 保底：每 7 天滚动
        return .init(rule: .rolling, param: 7, anchor: now.addingTimeInterval(168 * 3600),
                     explain: "未匹配到固定规律，按每 7 天滚动保底", repeatHours: 168)
    }

    /// rolling 周期小时数 → 整天数（供 resetParam 展示）；不足整天返回 nil
    private static func daysParam(forHours hours: Double) -> Int? {
        guard hours >= 24, hours.truncatingRemainder(dividingBy: 24) == 0 else { return nil }
        return Int(hours / 24)
    }

    static func infer(purchase: Date, expiry: Date, lastReset: Date,
                      now: Date = Date(), calendar: Calendar = .current) -> ResetInferenceResult {
        let week: TimeInterval = 7 * 86400
        let dPE = expiry.timeIntervalSince(purchase)
        let dPR = lastReset.timeIntervalSince(purchase)
        let pDay = calendar.component(.day, from: purchase)
        let rDay = calendar.component(.day, from: lastReset)
        let pTime = timeOfDaySeconds(purchase, calendar: calendar)
        let rTime = timeOfDaySeconds(lastReset, calendar: calendar)

        func monthName(_ p: Int) -> String { ["", "周一", "周二", "周三", "周四", "周五", "周六", "周日"][min(max(p, 1), 7)] }

        // 1) 完全同刻 + 7 天网格 → 自购买滚动的周额度（如买了 4 期）
        if dPR >= 0, dPE >= week,
           abs(dPR.truncatingRemainder(dividingBy: week)) <= 6 * 3600,
           abs(dPE.truncatingRemainder(dividingBy: week)) <= 6 * 3600, pTime == rTime {
            let periods = max(1, Int((dPE / week).rounded()))
            return .init(rule: .rolling, param: 7, anchor: lastReset,
                         explain: "自购买日(\(Fmt.absTime(purchase)))起每 7 天一期，共约 \(periods) 期周额度；已按最近重置(\(Fmt.absTime(lastReset)))自动滚动",
                         repeatHours: 168)
        }
        // 2) 最近重置的「几号」== 购买日的「几号」→ 订阅日锚定月
        if rDay == pDay {
            return .init(rule: .anchorMonth, param: pDay, anchor: lastReset,
                         explain: "每月 \(pDay) 号（订阅日）重置月额度，与到期日无关",
                         repeatHours: nil)
        }
        // 3) 最近重置为 00:00 整点 → 官方固定日历（与购买日无关）
        if rTime == 0 {
            if calendar.component(.weekday, from: lastReset) == calendar.component(.weekday, from: expiry) || dPE <= 32 * 86400 {
                let w = weekdayParam(lastReset, calendar: calendar)
                return .init(rule: .calendarWeek, param: w, anchor: lastReset,
                             explain: "官方固定每周\(monthName(w)) 00:00 重置周额度（千问式）",
                             repeatHours: nil)
            }
            return .init(rule: .calendarMonth, param: rDay, anchor: lastReset,
                         explain: "官方固定每月 \(rDay) 号重置（与你 \(pDay) 号的购买日无关）",
                         repeatHours: nil)
        }
        // 4) 保底：按最近重置时间滚动
        return .init(rule: .rolling, param: 7, anchor: lastReset,
                     explain: "未匹配到固定规律，按最近重置(\(Fmt.absTime(lastReset)))每 7 天滚动",
                     repeatHours: 168)
    }

    private static func timeOfDaySeconds(_ d: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.hour, .minute, .second], from: d)
        return (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
    }

    private static func weekdayParam(_ d: Date, calendar: Calendar) -> Int {
        // 参数语义：1=周一…7=周日；Calendar.weekday: 1=周日…7=周六
        let wd = calendar.component(.weekday, from: d)
        return wd == 1 ? 7 : wd - 1
    }
}

// MARK: - 伴生重置窗口工厂
// 从编辑表单的 syncQuotaReset 构造段提炼：保存推断管线与 UI 共用同一构造规则。

enum ResetWindowFactory {
    /// 生成 id = "qreset:" + parent.id 的伴生周期重置窗口（kind .window）。
    /// 滚动模式：expiresAt = 本轮到期锚点 + repeatHours，resetParam = 整天数，repeatHours = 小时数；
    /// 日历模式：expiresAt = parent.nextCalendarReset(after: now)，repeatHours = nil（独立于到期日，不平移）。
    static func companion(for parent: SubItem, rule: ResetRule, param: Int?,
                          repeatHours: Double?, now: Date = Date()) -> SubItem {
        var c = SubItem.manualDefault(name: "", vendor: parent.vendor)
        c.id = SubItem.quotaResetId(for: parent.id)
        c.kind = .window
        c.groupID = parent.groupID ?? parent.id
        c.name = parent.name.isEmpty ? "周期重置" : "\(parent.name)·周期重置"
        c.vendor = parent.vendor
        let calendar = rule == .calendarMonth || rule == .calendarWeek || rule == .anchorMonth
        if calendar, let param = param {
            c.resetRule = rule
            c.resetParam = param
            c.repeatHours = nil
            c.expiresAt = c.nextCalendarReset(after: now) ?? now
            switch rule {
            case .calendarMonth:
                c.note = "「\(parent.name)」每月 \(param) 日 00:00 重置额度，独立于到期日"
            case .calendarWeek:
                let names = ["", "周一", "周二", "周三", "周四", "周五", "周六", "周日"]
                c.note = "「\(parent.name)」每周 \(names[min(max(param, 1), 7)]) 00:00 重置额度，独立于到期日"
            default:
                c.note = "「\(parent.name)」每月订阅日 00:00 重置额度（订阅日锚定月）"
            }
        } else {
            // 滚动档位：repeatHours 供 rollManualWindows 按相位滚动；整天数写入 resetParam 供展示
            let hours = max(1, repeatHours ?? 168)
            c.resetRule = .rolling
            c.resetParam = hours.truncatingRemainder(dividingBy: 24) == 0 ? Int(hours / 24) : nil
            c.repeatHours = hours
            c.expiresAt = SubItem.nextRollingReset(anchor: parent.expiresAt.addingTimeInterval(hours * 3600), hours: hours, now: now) ?? parent.expiresAt
            c.note = hours.truncatingRemainder(dividingBy: 24) == 0
                ? "「\(parent.name)」每 \(Int(hours / 24)) 天额度重置，独立于到期日自动滚动"
                : "「\(parent.name)」每 \(Int(hours)) 小时额度重置，独立于到期日自动滚动"
        }
        return c
    }
}

/// 自动收起抑制器：说明弹窗/编辑期间抑制面板自动收起

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

/// 设置（轻量 KV，走 state.json）；记录类数据全部在 SQLite。
/// 旧 state.json 里已删除的 key（如 notifiedKeys/feishuWebhook）由合成 Codable 自动忽略。
struct AppState: Codable {
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
    /// 数据版本号：任何变更（写入/删除/滚动/归档/清理）成功路径 +1；UI 用它做变更检测
    private(set) var dataVersion: Int = 0

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
        upsertManual(item, alignCompanion: true)
    }

    /// 校验加固：repeatHours 清洗——>=1 放行；0<x<1 钳到 1；<=0 / 非有限值置 nil
    /// （防每秒 10 万次滚循环 + 每秒写库的病态路径）
    private static func sanitized(_ item: SubItem) -> SubItem {
        var item = item
        if let h = item.repeatHours {
            if !h.isFinite || h <= 0 { item.repeatHours = nil }
            else if h < 1 { item.repeatHours = 1 }
        }
        return item
    }

    private func upsertManual(_ item: SubItem, alignCompanion: Bool) -> ManualWriteResult {
        let item = Store.sanitized(item)
        let previous = manualItems.first { $0.id == item.id }
        let action = previous == nil ? "add" : "update"
        guard write(item, action: action) else { return .parentFailed }
        var failures: [String] = []
        if alignCompanion, let previous, previous.expiresAt != item.expiresAt,
           var reset = manualItems.first(where: { $0.id == SubItem.quotaResetId(for: item.id) }),
           reset.resetRule == nil || reset.resetRule == .rolling {
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
                if var reset = manualItems.first(where: { $0.id == "qreset:" + sibling.id }),
                   reset.resetRule == nil || reset.resetRule == .rolling {
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
            if write(Store.sanitized(item), action: item.groupID != nil ? "add_week" : "add") { written += 1 } else { failed += 1 }
        }
        manualItems = db.loadItems()
        if failed == 0 { return .success }
        return written > 0 ? .partialSaved(written: written, failed: failed) : .parentFailed
    }

    /// 编辑路径：写入父条目（保留调用方构造的 kind/resetRule/resetParam/purchaseAt，不被推断覆盖），
    /// 并在到期时间变化时同步平移 rolling 伴生窗口（action "align"）。
    /// 日历模式伴生不平移（独立于到期日）；previousExpiry 为 nil 或差值为 0 时不做伴生对齐。
    @discardableResult
    func updateManual(_ item: SubItem, previousExpiry: Date?, now: Date = Date()) -> ManualWriteResult {
        var result = upsertManual(item, alignCompanion: false)
        guard result.saved else { return result }
        // 条目本身转为周期窗口后，其名下的伴生重置窗口已冗余（双份滚动），移除
        if item.kind == .window {
            let cid = SubItem.quotaResetId(for: item.id)
            if manualItems.contains(where: { $0.id == cid }) {
                _ = deleteManual(id: cid)   // 内部 bump dataVersion 并回读
            }
        }
        guard let previous = previousExpiry else { return result }
        let delta = item.expiresAt.timeIntervalSince(previous)
        guard delta != 0,
              var companion = manualItems.first(where: { $0.id == SubItem.quotaResetId(for: item.id) }),
              companion.repeatHours != nil else { return result }   // 仅 rolling 档平移；日历档独立于到期日
        companion.expiresAt = companion.expiresAt.addingTimeInterval(delta)
        if !write(companion, action: "align") {
            let evidence = "align:\(companion.id)"
            switch result {
            case .success:
                result = .savedWithAlignFailure(failures: [evidence])
            case .savedWithAlignFailure(let fs):
                result = .savedWithAlignFailure(failures: fs + [evidence])
            default:
                break
            }
        }
        manualItems = db.loadItems()
        return result
    }

    /// 订阅 + 官方周额度重置（表单「订阅 · 周额度重置」档）：
    /// 重置节奏独立于订阅到期——自首次重置 anchor 起每 7 天一档（anchor + 7k ≤ 订阅到期），
    /// 生成「名称·第k/n周」组条目；重置次数由 anchor 与到期共同决定，最后一轮可能叠不满到期日。
    /// anchor 缺省 = now + 7 天（由表单默认值传入）；replacing = 升级为周组时被替换的原单条。
    @discardableResult
    func saveWeeklySplit(name: String, vendor: String?, expiry: Date, firstReset anchor: Date,
                         replacing: String? = nil, now: Date = Date()) -> ManualWriteResult {
        let trimmedVendor = (vendor ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedVendor = trimmedVendor.isEmpty
            ? (VendorResetKnowledge.vendor(for: name) ?? "未分类")
            : trimmedVendor
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = cleanedVendor }
        let span = expiry.timeIntervalSince(anchor)
        guard span.isFinite, span >= 0, span < 520 * 7 * 86400 else { return .parentFailed }
        let resets = (0...Int(floor(span / (7 * 86400)))).map {
            anchor.addingTimeInterval(Double($0) * 7 * 86400)
        }
        let n = resets.count
        let advice = QuotaAdvice.weeklyPlan(expiry: expiry, firstReset: anchor, now: now).advice
        let gid = UUID().uuidString
        let members = resets.enumerated().map { k, d -> SubItem in
            var v = SubItem.manualDefault(name: "\(base)·第\(k + 1)/\(n)周", vendor: cleanedVendor)
            v.expiresAt = d
            v.groupID = gid
            v.note = "官方周额度节奏：自 \(Fmt.absTime(anchor)) 每 7 天重置，共 \(n) 轮。" + advice.joined(separator: " ")
            return v
        }
        let ok = db.transaction {
            for member in members {
                guard write(member, action: "add_week") else { return false }
            }
            if let replacing {
                guard db.delete(id: replacing), db.delete(id: SubItem.quotaResetId(for: replacing)) else { return false }
            }
            return true
        }
        manualItems = db.loadItems()
        if ok { dataVersion += 1 }
        return ok ? .success : .parentFailed
    }

    @discardableResult
    func saveOneTime(name: String, vendor: String?, expiresAt: Date) -> ManualWriteResult {
        let clean = (vendor ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let vendor = clean.isEmpty ? (VendorResetKnowledge.vendor(for: name) ?? "未分类") : clean
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空名称兜底「供应商·订阅」：面板里不出现无名条目，且与 saveWindow 的「·周期额度」约定同构
        let name = trimmed.isEmpty ? vendor + "·订阅" : trimmed
        var item = SubItem.manualDefault(name: name, vendor: vendor)
        item.expiresAt = expiresAt
        return upsertManual(item)
    }

    /// 手动创建周期额度窗口（表单显式选择周期档，绕过推断）：
    /// kind .window + repeatHours，到期自动按周期滚动；窗口起点倒推 = 本轮到期 − 周期。
    /// 名称/供应商清洗与 saveInferred 同规则（空名称 → 「供应商·周期额度」）。
    @discardableResult
    func saveWindow(name: String, vendor: String?, expiresAt: Date,
                    repeatHours hours: Double, now: Date = Date()) -> ManualWriteResult {
        let trimmedVendor = (vendor ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedVendor = trimmedVendor.isEmpty
            ? (VendorResetKnowledge.vendor(for: name) ?? "未分类")
            : trimmedVendor
        var cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedName.isEmpty { cleanedName = cleanedVendor + "·周期额度" }
        guard hours.isFinite, hours > 0, hours <= 87600 else { return .parentFailed }
        let h = max(hours, 1)
        var w = SubItem.manualDefault(name: cleanedName, vendor: cleanedVendor)
        w.kind = .window
        w.repeatHours = h
        w.expiresAt = expiresAt
        w.purchaseAt = expiresAt.addingTimeInterval(-h * 3600)   // 倒推：窗口起点 = 本轮到期 − 周期
        w.resetRule = .rolling
        w.resetParam = h.truncatingRemainder(dividingBy: 24) == 0 ? Int(h / 24) : nil
        w.note = h >= 24 ? "周期额度：每 \(Int(h / 24)) 天滚动一轮，到期自动顺延"
                         : "周期额度：每 \(Int(h)) 小时滚动一轮，到期自动顺延"
        return upsertManual(w)
    }

    /// 智能保存管线：用户最少只填「名称(可空) + 到期时间(+供应商可空)」，底层自动补全其余。
    /// 1) 供应商清洗：空白 → 从名称反推厂商 → 仍无则「未分类」；
    /// 2) 名称清洗：空白 → 自动命名（供应商 + 有重置模型 ? "·周期额度" : "·订阅"）；
    /// 3) 重置节奏：同供应商历史 → 厂商知识库 → 购买→到期间隔推断；
    /// 4) 伴生重置窗口：仅当历史或厂商知识存在（未分类厂商不凭空造窗口）。
    @discardableResult
    func saveInferred(name: String, vendor: String?, expiresAt: Date, purchaseAt: Date?,
                      now: Date = Date()) -> ManualWriteResult {
        // 1) 供应商清洗
        let trimmedVendor = (vendor ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedVendor = trimmedVendor.isEmpty
            ? (VendorResetKnowledge.vendor(for: name) ?? "未分类")
            : trimmedVendor
        // 3) 历史与厂商知识（先于命名：决定自动命名的后缀）
        let history = lastResetModel(vendor: cleanedVendor)
        let historyHit: (rule: ResetRule?, param: Int?, repeatHours: Double?)? =
            history.flatMap { ($0.rule != nil || $0.repeatHours != nil) ? $0 : nil }
        let candidate = VendorResetKnowledge.bestCandidate(for: cleanedVendor)
        // 2) 名称清洗
        var cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedName.isEmpty {
            cleanedName = cleanedVendor + ((historyHit != nil || candidate != nil) ? "·周期额度" : "·订阅")
        }
        // 周期（小时）：历史 → 厂商知识 → 购买→到期间隔
        let knownHours = historyHit?.repeatHours ?? (historyHit == nil ? candidate?.repeatHours : nil)
        let periodHours = knownHours
            ?? purchaseAt.flatMap { ResetInference.inferPeriodHours(purchase: $0, expiry: expiresAt) }
        // 5) 父条目（purchaseAt 兜底：到期时间 − 已知周期，无周期按 30 天回推记录）
        var parent = SubItem.manualDefault(name: cleanedName, vendor: cleanedVendor)
        parent.expiresAt = expiresAt
        parent.purchaseAt = purchaseAt ?? expiresAt.addingTimeInterval(-(periodHours ?? 720) * 3600)
        // 7) note 注明推断来源
        if historyHit != nil {
            parent.note = "重置节奏：沿用同供应商历史重置节奏"
        } else if let c = candidate {
            parent.note = "重置节奏来源：\(cleanedVendor)（\(c.explain)）"
        } else if periodHours != nil {
            parent.note = "重置节奏：按购买→到期间隔推断"
        }
        let parentResult = upsertManual(parent)
        guard parentResult.saved else { return parentResult }
        // 6) 伴生重置窗口：仅当历史或厂商知识存在
        let model: (rule: ResetRule, param: Int?, repeatHours: Double?)?
        if let h = historyHit {
            model = (rule: h.rule ?? .rolling, param: h.param, repeatHours: h.repeatHours)
        } else if let c = candidate {
            model = (rule: c.rule, param: c.param, repeatHours: c.repeatHours)
        } else {
            model = nil
        }
        guard let model else { return parentResult }
        let companion = ResetWindowFactory.companion(for: parent, rule: model.rule, param: model.param,
                                                     repeatHours: model.repeatHours, now: now)
        if upsertManual(companion).saved { return .success }
        return .savedWithAlignFailure(failures: ["add:\(companion.id)"])
    }

    // MARK: 推断输入查询

    /// 可滚动窗口的最早到期时间（nil = 无可滚动窗口）。
    /// 只统计真正能滚动的窗口：归档窗口不再驱动滚动；卡死窗口（repeatHours 无效、
    /// 日历参数算不出下一节点）排除——否则 deadline 永远停在过去，roll 分支每秒空转。
    func nextRollInstant(now: Date = Date()) -> Date? {
        manualItems.filter { item in
            guard item.kind == .window, item.archivedAt == nil else { return false }
            switch item.resetRule {
            case .calendarMonth, .calendarWeek, .anchorMonth:
                return item.nextCalendarReset(after: now) != nil
            default:
                return SubItem.nextRollingReset(anchor: item.expiresAt, hours: item.repeatHours ?? 0, now: now) != nil
            }
        }.map(\.expiresAt).min()
    }

    /// 同供应商最近一条带重置模型的手动窗口（按 updatedAt 降序，vendor 大小写不敏感）
    func lastResetModel(vendor: String) -> (rule: ResetRule?, param: Int?, repeatHours: Double?)? {
        let key = vendor.lowercased()
        let newest = manualItems
            .filter { $0.kind == .window && $0.vendor.lowercased() == key
                      && ($0.resetRule != nil || $0.repeatHours != nil) }
            .max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
        guard let newest else { return nil }
        return (rule: newest.resetRule, param: newest.resetParam, repeatHours: newest.repeatHours)
    }

    /// 实际写入（测试注入缝）：优先走 upsertInjection；成功路径 bump dataVersion
    private func write(_ item: SubItem, action: String) -> Bool {
        let ok = upsertInjection?(item, action) ?? db.upsert(item, action: action)
        if ok { dataVersion += 1 }
        return ok
    }

    /// 删除失败返回 false；调用方据此向用户反馈
    @discardableResult
    func deleteManual(id: String) -> Bool {
        let ok = db.delete(id: id)
        if ok { dataVersion += 1 }
        manualItems = db.loadItems()
        return ok
    }

    /// 删除手动条目及其派生的周额度重置窗口（qreset: 前缀）
    func deleteManualWithDerived(_ id: String) {
        let removedParent = db.delete(id: id)
        let removedCompanion = db.delete(id: SubItem.quotaResetId(for: id))
        if removedParent || removedCompanion { dataVersion += 1 }
        manualItems = db.loadItems()
    }

    /// 批量删除手动条目及其派生的周额度重置窗口（清理过期路径使用）
    func deleteManualsWithDerived(_ ids: [String]) {
        var any = false
        for id in ids {
            let removedParent = db.delete(id: id)
            let removedCompanion = db.delete(id: SubItem.quotaResetId(for: id))
            if removedParent || removedCompanion { any = true }
        }
        if any { dataVersion += 1 }
        manualItems = db.loadItems()
    }

    /// 删除整组（按周划分），返回删除条数
    @discardableResult
    func deleteGroup(_ groupID: String) -> Int {
        let n = db.deleteGroup(groupID)
        if n > 0 { dataVersion += 1 }
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
        var removed = 0
        ids.forEach { if db.delete(id: $0, action: "clean_expired") { removed += 1 } }
        if removed > 0 { dataVersion += 1 }
        manualItems = db.loadItems()
        return removed
    }

    /// 周期窗口到期后推进到下一次（写回数据库）。
    /// rolling：按 repeatHours 整倍数前滚（相位保持）；
    /// 日历模型：跳到下一个未来节点（离线跨周期不累积——错过的日历节点不会补）
    func rollManualWindows(now: Date = Date()) {
        var rolled = false
        for i in manualItems.indices {
            guard manualItems[i].kind == .window, !manualItems[i].isArchived,
                  manualItems[i].expiresAt <= now else { continue }
            let next: Date?
            switch manualItems[i].resetRule {
            case .calendarMonth, .calendarWeek, .anchorMonth:
                next = manualItems[i].nextCalendarReset(after: now)
            default:
                next = SubItem.nextRollingReset(anchor: manualItems[i].expiresAt,
                                               hours: manualItems[i].repeatHours ?? 0, now: now)
            }
            guard let next else { continue }
            var updated = manualItems[i]
            updated.expiresAt = next
            if write(updated, action: "roll") {
                manualItems[i] = updated
                rolled = true
            }
        }
        if rolled { manualItems.sort { $0.expiresAt < $1.expiresAt } }
    }

    /// 生命周期：手动订阅过期超过 days 天且未归档 → 打上归档时间（面板隐藏，保留期内可清理）。
    /// 伴生重置窗口随父一并归档——订阅已死，「下次重置」不再有意义，否则成孤儿窗口常驻面板。
    func archiveExpiredSubscriptions(olderThan days: Double = 3, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-days * 86400)
        for i in manualItems.indices {
            let it = manualItems[i]
            guard it.kind == .subscription, it.source == "manual",
                  it.archivedAt == nil, it.expiresAt < cutoff else { continue }
            var archived = it
            archived.archivedAt = now
            if write(archived, action: "archive") {
                manualItems[i].archivedAt = now
                if let j = manualItems.firstIndex(where: {
                    $0.id == SubItem.quotaResetId(for: it.id) && $0.archivedAt == nil
                }) {
                    var comp = manualItems[j]
                    comp.archivedAt = now
                    if write(comp, action: "archive") {
                        manualItems[j].archivedAt = now
                    }
                }
            }
        }
    }

    /// 生命周期：归档超过 days 天的条目连伴生窗口一起清除
    func purgeArchived(olderThan days: Double = 30, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-days * 86400)
        let ids = manualItems
            .filter { if let a = $0.archivedAt { return a < cutoff }; return false }
            .map { $0.id }
        guard !ids.isEmpty else { return }
        deleteManualsWithDerived(ids)   // 成功路径内部 bump dataVersion
    }

    /// 操作历史（最近 N 条，倒序）
    func recentHistory(limit: Int = 50) -> [(date: Date, action: String, summary: String)] {
        db.recentHistory(limit: limit)
    }
}

// MARK: - 时间格式化

enum Fmt {
    // 缓存的格式化器：Swift static let 初始化线程安全；DateFormatter 本身非线程安全，
    // 但本项目无并发访问（主线程 tick + Readers 后台仅用各自的 iso8601 解析器，不经由此处）。
    private static let absFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = .current
        return f
    }()

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = .current
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        f.timeZone = .current
        return f
    }()

    static func countdown(until: Date, now: Date = Date()) -> String {
        let sec = until.timeIntervalSince(now)
        if sec <= -86400 { return "已过期 \(-Int(sec) / 86400)天+" }
        if sec <= 0 { return sec > -60 ? "已过期" : "已过期\(-Int(sec) / 60)分" }
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
        absFormatter.string(from: d)
    }

    static func clock(_ d: Date) -> String {
        clockFormatter.string(from: d)
    }

    /// 排期展示用短日期（M/d）
    static func shortDate(_ d: Date) -> String {
        shortDateFormatter.string(from: d)
    }
}

// MARK: - 周额度排期建议（计算性建议引擎）

enum QuotaAdvice {
    struct Plan {
        let resets: [Date]       // 每轮重置时点（正推，含首末；末轮可能叠不满订阅到期）
        let advice: [String]     // 计算性建议（首/末轮非常规节奏时给出）
    }

    /// 输入「订阅到期 + 首次重置」自动填补全部重置时点，并给出计算性建议：
    /// - 首轮短于 7 天（官方锚定）→「这几天快点用」
    /// - 末轮短于 7 天（叠不满订阅到期）→ 白嫖天数 + 续买建议（再等 leftover 天，避免新窗口重叠）
    /// - 末轮重置即到期 → 该轮额度基本来不及用
    static func weeklyPlan(expiry: Date, firstReset: Date, now: Date = Date()) -> Plan {
        guard firstReset <= expiry else {
            return Plan(resets: [], advice: ["首次重置需早于（或等于）订阅到期"])
        }
        let week = 7.0 * 86400
        var resets: [Date] = []
        var t = firstReset
        while t <= expiry {
            resets.append(t)
            t = t.addingTimeInterval(week)
        }
        var advice: [String] = []
        if firstReset > now {
            let days = Int(ceil(firstReset.timeIntervalSince(now) / 86400))
            if days < 7 { advice.append("首轮只有 \(days) 天：这几天快点用") }
        }
        let last = resets[resets.count - 1]
        let tailDays = expiry.timeIntervalSince(last) / 86400
        let leftover = Int(ceil(last.addingTimeInterval(week).timeIntervalSince(expiry) / 86400))
        let until = Fmt.shortDate(last.addingTimeInterval(week))
        if tailDays >= 1 {
            let d = Int(tailDays.rounded(.up))
            advice.append("末轮只剩 \(d) 天（\(d) 天白嫖一周额度）；续买建议再等 \(leftover) 天（至 \(until)）再买，避免额度重叠")
        } else {
            advice.append("末轮重置即到期（该轮额度几乎来不及用）；续买建议等 \(leftover) 天（至 \(until)）本轮额度耗尽后再买")
        }
        return Plan(resets: resets, advice: advice)
    }
}
