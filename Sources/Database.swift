import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - SQLite 持久化
// 手动条目 + 操作历史全部入库；重启/更新/崩溃都不会丢（WAL + 事务）。

final class Database {
    private var handle: OpaquePointer?
    private let path: URL

    init(dir: URL, filename: String = "data.sqlite") {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent(filename)
        let rc = sqlite3_open_v2(path.path, &handle,
                                 SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                                 nil)
        guard rc == SQLITE_OK, handle != nil else {
            // ④ SQLite 规范：open_v2 返回非 OK 时 *ppDb 若非空仍必须由调用方 close_v2，否则句柄泄漏；
            //    errmsg 要在关闭之前取（关闭后该指针失效）。
            let detail = Self.errorText(handle: handle)
            if let opened = handle { sqlite3_close_v2(opened) }
            handle = nil
            NSLog("AR: 数据库打开失败 \(path.path): \(Self.rcName(rc)) — \(detail)")
            return
        }
        sqlite3_busy_timeout(handle, 2000)
        exec("PRAGMA journal_mode=WAL;")
        createSchema()
        pruneHistory(force: true)   // ⑤ 启动即清一次历史（90 天前的行）
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    // MARK: 诊断（错误码/错误文本；step 的 DONE 与失败必须区分开，见 ①）

    /// 错误码 → 可读名。扩展位（如 SQLITE_BUSY_SNAPSHOT=517）按主码归一，日志里仍带原值。
    private static func rcName(_ rc: Int32) -> String {
        let primary = rc & 0xFF
        let base: String
        switch primary {
        case SQLITE_OK: base = "SQLITE_OK"
        case SQLITE_ERROR: base = "SQLITE_ERROR（SQL 语法/表缺失）"
        case SQLITE_NOMEM: base = "SQLITE_NOMEM（内存不足）"
        case SQLITE_BUSY: base = "SQLITE_BUSY（库被占用，已超出 busy_timeout）"
        case SQLITE_LOCKED: base = "SQLITE_LOCKED（表级锁）"
        case SQLITE_CONSTRAINT: base = "SQLITE_CONSTRAINT（约束冲突）"
        case SQLITE_CORRUPT: base = "SQLITE_CORRUPT（库损坏）"
        case SQLITE_READONLY: base = "SQLITE_READONLY（只读）"
        case SQLITE_INTERRUPT: base = "SQLITE_INTERRUPT（被打断）"
        case SQLITE_IOERR: base = "SQLITE_IOERR（磁盘 I/O）"
        case SQLITE_FULL: base = "SQLITE_FULL（磁盘满）"
        case SQLITE_CANTOPEN: base = "SQLITE_CANTOPEN（打不开文件）"
        case SQLITE_PROTOCOL: base = "SQLITE_PROTOCOL（锁协议超时）"
        case SQLITE_TOOBIG: base = "SQLITE_TOOBIG（行/值过大）"
        case SQLITE_ABORT: base = "SQLITE_ABORT（回调中止）"
        default: base = "rc=\(primary)"
        }
        return primary == rc ? base : "\(base)/原值 \(rc)"
    }

    /// sqlite3_errmsg 在 OOM 时也可能返回 NULL，这里不做强解包。
    private static func errorText(handle: OpaquePointer?) -> String {
        guard let handle else { return "数据库未打开" }
        let ptr: UnsafePointer<CChar>? = sqlite3_errmsg(handle)
        return ptr.map { String(cString: $0) } ?? "无错误信息"
    }

    private func dbError() -> String { Self.errorText(handle: handle) }

    /// step 退出码 → 可读原因；SQLITE_DONE（正常收尾）返回 nil。
    private func stepMessage(_ rc: Int32) -> String? {
        guard rc != SQLITE_DONE else { return nil }
        return "\(Self.rcName(rc)) — \(dbError())"
    }

    /// prepare + 统一失败日志；调用方仍在自己身上 defer { sqlite3_finalize(stmt) }（配对不变）。
    private func prepare(_ sql: String, statement: inout OpaquePointer?) -> Bool {
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        if rc != SQLITE_OK {
            NSLog("AR: prepare 失败 \(Self.rcName(rc)) — \(dbError()) | sql=\(sql.prefix(70))")
        }
        return rc == SQLITE_OK
    }

    /// Int → Int32 边界 guard：直接 Int32(p) 越界会整型溢出 trap（现调用点最大 3650，防后续复用）。
    private func int32(_ value: Int, field: String, id: String? = nil) -> Int32? {
        guard value >= Int(Int32.min), value <= Int(Int32.max) else {
            NSLog("AR: \(field) 超出 Int32 范围(\(value))\(id.map { " id=\($0)" } ?? "")，由调用方降级处理")
            return nil
        }
        return Int32(value)
    }

    /// ③ 文本列安全读取：NULL 与 OOM 都返回 nil。
    /// 原写法 String(cString: sqlite3_column_text(...)) 依赖 IUO，`id TEXT PRIMARY KEY` 不带 NOT NULL，
    /// 真出现 NULL 就是崩溃；本文件其余列早已用 .map 可选写法，这里统一。
    private static func text(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard let stmt, sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        let ptr: UnsafePointer<UInt8>? = sqlite3_column_text(stmt, col)
        return ptr.map { String(cString: $0) }
    }

    /// 数值/时间列安全读取：NULL、非数值存储类（REAL 列里塞了 TEXT 时 column_double 返回 0.0，
    /// 也就是「1970 年前已过期」的另一条来路）与非有限值都判为坏值（②）。
    private static func timestamp(_ stmt: OpaquePointer?, _ col: Int32) -> Double? {
        guard let stmt else { return nil }
        switch sqlite3_column_type(stmt, col) {
        case SQLITE_INTEGER:
            let value = Double(sqlite3_column_int64(stmt, col))
            return value.isFinite ? value : nil
        case SQLITE_FLOAT:
            let value = sqlite3_column_double(stmt, col)
            return value.isFinite ? value : nil
        default:
            return nil
        }
    }

    private func createSchema() {
        exec("""
        CREATE TABLE IF NOT EXISTS items (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            vendor TEXT,
            kind TEXT,
            expires_at REAL,
            repeat_hours REAL,
            source TEXT,
            note TEXT,
            used_percent REAL,
            group_id TEXT,
            created_at REAL,
            updated_at REAL,
            reset_rule TEXT,
            reset_param INTEGER
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_items_group ON items(group_id);")
        // 独立保存提醒偏好，既支持手动记录，也支持不入 items 的官方条目。
        exec("""
        CREATE TABLE IF NOT EXISTS reminder_settings (
            item_id TEXT PRIMARY KEY NOT NULL,
            before_hours INTEGER NOT NULL CHECK(before_hours > 0)
        );
        """)
        // v2 迁移：旧库补重置规则列（重复执行时列已存在，exec 会记录一条无害日志）
        if !columnExists("items", "reset_rule") {
            exec("ALTER TABLE items ADD COLUMN reset_rule TEXT;")
        }
        if !columnExists("items", "reset_param") {
            exec("ALTER TABLE items ADD COLUMN reset_param INTEGER;")
        }
        // v3 迁移：智能推断管线的购买/归档时间列（旧库残留的 alert_before 列无害，不 DROP）
        if !columnExists("items", "purchase_at") {
            exec("ALTER TABLE items ADD COLUMN purchase_at REAL;")
        }
        if !columnExists("items", "archived_at") {
            exec("ALTER TABLE items ADD COLUMN archived_at REAL;")
        }
        exec("""
        CREATE TABLE IF NOT EXISTS history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts REAL NOT NULL,
            action TEXT NOT NULL,
            item_id TEXT,
            summary TEXT
        );
        """)
        // ⑤ recentHistory 走 ORDER BY ts DESC LIMIT ?：没有索引就是全表扫描，历史上万行时明显变慢
        exec("CREATE INDEX IF NOT EXISTS idx_history_ts ON history(ts);")
    }

    /// 已知表名白名单：PRAGMA 无法用占位符绑定表名，只能「校验 + 引号」后拼接（⑦）。
    /// 现调用方只传字面量，加白名单是防后续复用把外部字符串带进来。
    private static let knownTables: Set<String> = ["items", "history"]

    /// 列是否存在（迁移守卫，避免每次启动的重复 ALTER 日志）
    private func columnExists(_ table: String, _ column: String) -> Bool {
        guard Self.knownTables.contains(table) else {
            NSLog("AR: columnExists 拒绝未知表名「\(table)」，不做迁移判断")
            return false
        }
        var stmt: OpaquePointer?
        guard prepare("PRAGMA table_info(\"\(table)\");", statement: &stmt) else { return false }
        defer { sqlite3_finalize(stmt) }
        var found = false
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            // ③ column_text 可能为 NULL（IUO 解包即崩）
            if Self.text(stmt, 1) == column { found = true }
            rc = sqlite3_step(stmt)
        }
        if rc != SQLITE_DONE {   // ① 中途失败时 found 可能是假阴性，必须留痕
            NSLog("AR: columnExists(\(table)) 读取中断 \(stepMessage(rc) ?? "")")
        }
        return found
    }

    @discardableResult
    private func execOK(_ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            NSLog("AR: SQL 错误 \(Self.rcName(rc)) \(sql.prefix(60))…: \(err.map { String(cString: $0) } ?? "未知")")
            if let err { free(err) }
        }
        return rc == SQLITE_OK
    }

    private func exec(_ sql: String) { _ = execOK(sql) }

    /// 分周转换要么全部成功，要么保留原记录与操作历史。
    /// ⑥ 不支持嵌套：内层 BEGIN 在 SQLite 侧直接报 "cannot start a transaction within a transaction"，
    /// 原来的写法会把它当成「事务体失败」静默返回 false，外层还照常 COMMIT，结果一半生效。
    func transaction(_ body: () -> Bool) -> Bool {
        guard handle != nil else { NSLog("AR: transaction: 数据库未打开，拒绝执行"); return false }
        if sqlite3_get_autocommit(handle) == 0 {
            NSLog("AR: transaction 不支持嵌套：已在事务中（autocommit=0），本次直接失败且不重复 BEGIN")
            return false
        }
        guard execOK("BEGIN IMMEDIATE") else { return false }
        let bodyOK = body()
        if bodyOK, execOK("COMMIT") { return true }
        NSLog("AR: transaction 需要回滚：事务体\(bodyOK ? "成功但 COMMIT 失败" : "返回 false")")
        // COMMIT 失败时 SQLite 多数已自行回滚；仍在事务里才发 ROLLBACK，并把真实错误记下来
        if sqlite3_get_autocommit(handle) == 0 {
            if !execOK("ROLLBACK") { NSLog("AR: ROLLBACK 失败，事务可能仍打开：\(dbError())") }
        } else {
            NSLog("AR: 事务已在 SQLite 侧结束（autocommit 已恢复），无需 ROLLBACK")
        }
        return false
    }

    // MARK: 条目 CRUD

    func loadReminderHours() -> [String: Int] {
        var result: [String: Int] = [:]
        var stmt: OpaquePointer?
        guard prepare("SELECT item_id, before_hours FROM reminder_settings;", statement: &stmt) else { return result }
        defer { sqlite3_finalize(stmt) }
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            if let id = Self.text(stmt, 0), !id.isEmpty,
               sqlite3_column_type(stmt, 1) == SQLITE_INTEGER {
                let hours = sqlite3_column_int64(stmt, 1)
                if hours >= 1 && hours <= Int64(ReminderTiming.maxHours) { result[id] = Int(hours) }
            }
            rc = sqlite3_step(stmt)
        }
        if let reason = stepMessage(rc) { NSLog("AR: 读取提醒设置中断：\(reason)") }
        return result
    }

    @discardableResult
    func setReminderHours(_ hours: Int, for id: String) -> Bool {
        guard (1...ReminderTiming.maxHours).contains(hours), !id.isEmpty else { return false }
        var stmt: OpaquePointer?
        guard prepare("""
            INSERT INTO reminder_settings(item_id, before_hours) VALUES (?, ?)
            ON CONFLICT(item_id) DO UPDATE SET before_hours=excluded.before_hours;
            """, statement: &stmt) else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, sqliteTransient)
        sqlite3_bind_int64(stmt, 2, Int64(hours))
        let rc = sqlite3_step(stmt)
        if let reason = stepMessage(rc) { NSLog("AR: 保存提醒设置失败 id=\(id)：\(reason)") }
        return rc == SQLITE_DONE
    }

    @discardableResult
    func upsert(_ item: SubItem, action: String) -> Bool {
        let sql = """
        INSERT INTO items (id,name,vendor,kind,expires_at,repeat_hours,source,note,used_percent,group_id,created_at,updated_at,reset_rule,reset_param,purchase_at,archived_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            name=excluded.name, vendor=excluded.vendor, kind=excluded.kind,
            expires_at=excluded.expires_at, repeat_hours=excluded.repeat_hours,
            source=excluded.source, note=excluded.note,
            used_percent=excluded.used_percent, group_id=excluded.group_id, updated_at=excluded.updated_at,
            reset_rule=excluded.reset_rule, reset_param=excluded.reset_param,
            purchase_at=excluded.purchase_at, archived_at=excluded.archived_at;
        """
        var stmt: OpaquePointer?
        guard prepare(sql, statement: &stmt) else { return false }
        defer { sqlite3_finalize(stmt) }
        let now = Date().timeIntervalSince1970
        let created = action == "add" ? now : (createdAt(of: item.id) ?? now)
        sqlite3_bind_text(stmt, 1, (item.id as NSString).utf8String, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 2, (item.name as NSString).utf8String, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 3, (item.vendor as NSString).utf8String, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 4, (item.kind.rawValue as NSString).utf8String, -1, sqliteTransient)
        sqlite3_bind_double(stmt, 5, item.expiresAt.timeIntervalSince1970)
        if let h = item.repeatHours { sqlite3_bind_double(stmt, 6, h) } else { sqlite3_bind_null(stmt, 6) }
        sqlite3_bind_text(stmt, 7, (item.source as NSString).utf8String, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 8, (item.note as NSString).utf8String, -1, sqliteTransient)
        if let u = item.usedPercent { sqlite3_bind_double(stmt, 9, u) } else { sqlite3_bind_null(stmt, 9) }
        if let g = item.groupID { sqlite3_bind_text(stmt, 10, (g as NSString).utf8String, -1, sqliteTransient) } else { sqlite3_bind_null(stmt, 10) }
        sqlite3_bind_double(stmt, 11, created)
        sqlite3_bind_double(stmt, 12, now)
        if let r = item.resetRule { sqlite3_bind_text(stmt, 13, (r.rawValue as NSString).utf8String, -1, sqliteTransient) } else { sqlite3_bind_null(stmt, 13) }
        // ⑧ Int32(p) 越界会整型溢出 trap：越界记日志并按 NULL 绑（宁可少一个参数，不崩整条写入）
        if let p = item.resetParam, let p32 = int32(p, field: "reset_param", id: item.id) { sqlite3_bind_int(stmt, 14, p32) } else { sqlite3_bind_null(stmt, 14) }
        if let p = item.purchaseAt { sqlite3_bind_double(stmt, 15, p.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 15) }
        if let a = item.archivedAt { sqlite3_bind_double(stmt, 16, a.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 16) }
        // ① DONE 之外的 BUSY/NOMEM/CONSTRAINT/… 都是「没写进去」，必须带真实原因，而不是只回 false
        let rc = sqlite3_step(stmt)
        let ok = rc == SQLITE_DONE
        if ok {
            log(action: action, itemId: item.id, summary: item.name)
        } else if let reason = stepMessage(rc) {
            NSLog("AR: upsert 失败 id=\(item.id) action=\(action) name=\(item.name): \(reason)")
        }
        return ok
    }

    @discardableResult
    func delete(id: String, action: String = "delete") -> Bool {
        // ⑧ 只为日志取这一条的名字，不再做一次全表 loadItems()
        let itemName = name(of: id) ?? id
        var stmt: OpaquePointer?
        guard prepare("DELETE FROM items WHERE id = ?;", statement: &stmt) else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, sqliteTransient)
        let rc = sqlite3_step(stmt)
        let ok = rc == SQLITE_DONE
        if ok {
            log(action: action, itemId: id, summary: itemName)
        } else if let reason = stepMessage(rc) {
            NSLog("AR: delete 失败 id=\(id) action=\(action): \(reason)")
        }
        return ok
    }

    @discardableResult
    func deleteGroup(_ groupID: String) -> Int {
        // ⑧ 直接按 group_id 取成员名：计数即「真正被删的行数」，不受坏行解析跳过影响
        let members = names(groupID: groupID)
        var stmt: OpaquePointer?
        guard prepare("DELETE FROM items WHERE group_id = ?;", statement: &stmt) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (groupID as NSString).utf8String, -1, sqliteTransient)
        let rc = sqlite3_step(stmt)
        let ok = rc == SQLITE_DONE
        if ok {
            log(action: "delete_group", itemId: groupID, summary: members.joined(separator: ", "))
        } else if let reason = stepMessage(rc) {
            NSLog("AR: deleteGroup 失败 group=\(groupID)（\(members.count) 个成员未确认删除）: \(reason)")
        }
        return ok ? members.count : 0
    }

    /// 单条名字（日志用）；读不到就返回 nil 由调用方回退成 id。
    private func name(of id: String) -> String? {
        var stmt: OpaquePointer?
        guard prepare("SELECT name FROM items WHERE id = ?;", statement: &stmt) else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, sqliteTransient)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return Self.text(stmt, 0) }
        if let reason = stepMessage(rc) {
            NSLog("AR: 查询条目名失败 id=\(id): \(reason)")   // 坏值不影响删除，只影响历史摘要
        }
        return nil
    }

    /// 组内成员名字（日志用），顺序与原 loadItems 过滤一致（按插入序即可）。
    private func names(groupID: String) -> [String] {
        var result: [String] = []
        var stmt: OpaquePointer?
        guard prepare("SELECT name FROM items WHERE group_id = ?;", statement: &stmt) else { return result }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (groupID as NSString).utf8String, -1, sqliteTransient)
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            result.append(Self.text(stmt, 0) ?? "(无名)")
            rc = sqlite3_step(stmt)
        }
        if rc != SQLITE_DONE {
            NSLog("AR: 查询组成员名中断 group=\(groupID) \(stepMessage(rc) ?? "")，已取 \(result.count) 行")
        }
        return result
    }

    func loadItems() -> [SubItem] { loadItemsChecked().items }

    /// ① 与 loadItems 并行的「带完整性判据」读法（签名不变的原 API 仍可用）。
    /// complete == false 表示 step 以 BUSY/NOMEM/CORRUPT… 退出，items 只是**半读结果**：
    /// 调用方此时不得用它覆盖 manualItems，否则 align_week / 清理过期 会基于残缺集合做删除决策。
    /// 期望用法（由主控串行接线）：
    ///   let snap = db.loadItemsChecked()
    ///   guard snap.complete else { NSLog("AR: 本次读不完整，保留内存缓存"); return }
    ///   manualItems = snap.items
    /// ignored 是 ② ③ 里被跳过的坏行数（NULL 主键/NULL expires_at/无法识别的 kind、reset_rule）。
    func loadItemsChecked() -> (items: [SubItem], complete: Bool, ignored: Int) {
        var result: [SubItem] = []
        var ignored = 0
        guard handle != nil else {
            NSLog("AR: loadItems 跳过：数据库未打开（返回空集合且标记为不完整）")
            return ([], false, 0)
        }
        var stmt: OpaquePointer?
        guard prepare(
            "SELECT id,name,vendor,kind,expires_at,repeat_hours,source,note,used_percent,group_id,reset_rule,reset_param,updated_at,purchase_at,archived_at FROM items ORDER BY expires_at;",
            statement: &stmt), let cursor = stmt else { return (result, false, 0) }
        defer { sqlite3_finalize(cursor) }
        var rowIndex = 0
        var rc = sqlite3_step(cursor)
        while rc == SQLITE_ROW {
            rowIndex += 1
            if let item = Self.item(from: cursor, row: rowIndex) {
                result.append(item)
            } else {
                ignored += 1     // 行级原因已在 item(from:) 里带 id 记过日志
            }
            rc = sqlite3_step(cursor)
        }
        if rc != SQLITE_DONE {
            NSLog("AR: loadItems 读取中断 \(stepMessage(rc) ?? "")｜已取 \(result.count) 行、忽略 \(ignored) 行 → 结果不完整，不可覆盖内存缓存")
            return (result, false, ignored)
        }
        if ignored > 0 {
            NSLog("AR: loadItems 读完 \(result.count) 行，另有 \(ignored) 行因坏值被忽略（见上面的行级告警）")
        }
        return (result, true, ignored)
    }

    /// 单行解析。② 的原则：坏值一律「跳过 + 日志」，绝不用兜底值造一个看起来合法的对象——
    /// 坏值冒充合法值后，日历条目会按 repeatHours 乱滚，且 nextRoll == nil 会命中清理过期的永久删除路径。
    /// 注意：跳过只是不显示，删除都按显式 id/group_id 走，坏行仍留在库里等待修复。
    private static func item(from stmt: OpaquePointer, row: Int) -> SubItem? {
        guard let id = text(stmt, 0), !id.isEmpty else {
            NSLog("AR: 第 \(row) 行 id 为 NULL/空文本，跳过（name=\(text(stmt, 1) ?? "NULL")）")
            return nil
        }
        guard let name = text(stmt, 1) else {
            NSLog("AR: 条目 \(id) 的 name 为 NULL，跳过")
            return nil
        }
        guard let expiresTS = timestamp(stmt, 4) else {
            NSLog("AR: 条目 \(id) 的 expires_at 不是可用数值（NULL/文本/NaN），跳过（否则会被当成 1970 年已过期并顶到列表第一行）")
            return nil
        }
        guard let rawKind = text(stmt, 3) else {
            NSLog("AR: 条目 \(id) 的 kind 为 NULL，跳过（不再默认 subscription，窗口会被当成一次性订阅）")
            return nil
        }
        guard let kind = parseKind(rawKind) else {
            NSLog("AR: 条目 \(id) 的 kind「\(rawKind)」无法识别，跳过")
            return nil
        }
        // reset_rule：NULL 是合法值（语义就是 rolling）；非 NULL 却认不出来必须跳过，
        // 因为兜底成 nil 会被 Models 当成 rolling。
        var rule: ResetRule?
        if let rawRule = text(stmt, 10) {
            guard let parsed = parseRule(rawRule) else {
                NSLog("AR: 条目 \(id) 的 reset_rule「\(rawRule)」无法识别，跳过（兜底成 nil 会被当成 rolling：日历条目按 repeatHours 乱滚，并被清理过期永久删除）")
                return nil
            }
            rule = parsed
        }
        let repeatHours = doubleOrNil(stmt, 5)
        let used = doubleOrNil(stmt, 8)
        let group = text(stmt, 9)
        let param = intOrNil(stmt, 11)
        if let rule, rule != .rolling, param == nil {
            NSLog("AR: 条目 \(id) 的 \(rule.rawValue) 缺 reset_param，按「滚不动」处理（保留显示，不参与滚动）")
        }
        return SubItem(id: id, name: name, vendor: text(stmt, 2) ?? "",
                       kind: kind,
                       expiresAt: Date(timeIntervalSince1970: expiresTS),
                       repeatHours: repeatHours,
                       source: text(stmt, 6) ?? "manual",
                       note: text(stmt, 7) ?? "",
                       usedPercent: used, groupID: group,
                       resetRule: rule, resetParam: param,
                       purchaseAt: dateOrNil(stmt, 13), archivedAt: dateOrNil(stmt, 14),
                       updatedAt: dateOrNil(stmt, 12))
    }

    /// kind 严格解析；仅对大小写不规范的历史值容错（识别成功后下次 upsert 会写回规范值）。
    private static func parseKind(_ raw: String) -> ItemKind? {
        if let exact = ItemKind(rawValue: raw) { return exact }
        guard let folded = ItemKind(rawValue: raw.lowercased()) else { return nil }
        NSLog("AR: kind「\(raw)」大小写不规范，按 \(folded.rawValue) 读取")
        return folded
    }

    /// reset_rule 严格解析（同上，只对大小写容错）。
    private static func parseRule(_ raw: String) -> ResetRule? {
        if let exact = ResetRule(rawValue: raw) { return exact }
        switch raw.lowercased() {
        case "rolling": return .rolling
        case "calendarmonth": return .calendarMonth
        case "calendarweek": return .calendarWeek
        case "anchormonth": return .anchorMonth
        default: return nil
        }
    }

    private static func doubleOrNil(_ stmt: OpaquePointer, _ col: Int32) -> Double? {
        guard let value = timestamp(stmt, col) else {
            logBadNumericColumn(stmt, col)
            return nil
        }
        return value
    }

    /// reset_param：TEXT/BLOB 之类的坏值按 NULL 处理（坏值当 0 会让日历规则永远滚不动还不留痕）
    private static func intOrNil(_ stmt: OpaquePointer, _ col: Int32) -> Int? {
        guard let value = timestamp(stmt, col) else {
            logBadNumericColumn(stmt, col)
            return nil
        }
        // Int(Double) 对超出范围的值会 trap（这里绝不能用 Int() 裸转）
        guard value >= Double(Int32.min), value <= Double(Int32.max) else {
            NSLog("AR: 列 \(col) 数值 \(value) 超出 Int32 可表示范围，按 NULL 处理")
            return nil
        }
        return Int(value)
    }

    /// NULL 是合法状态（不记日志）；只有「非数值存储类」才是需要留痕的坏值。
    private static func logBadNumericColumn(_ stmt: OpaquePointer, _ col: Int32) {
        let type = sqlite3_column_type(stmt, col)
        guard type != SQLITE_NULL else { return }
        let namePtr: UnsafePointer<CChar>? = sqlite3_column_name(stmt, col)
        let name = namePtr.map { String(cString: $0) } ?? "列\(col)"
        NSLog("AR: \(name) 不是可用数值（存储类型 \(type)），按 NULL 处理")
    }

    private static func dateOrNil(_ stmt: OpaquePointer, _ col: Int32) -> Date? {
        guard let ts = timestamp(stmt, col) else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    private func createdAt(of id: String) -> Double? {
        var stmt: OpaquePointer?
        guard prepare("SELECT created_at FROM items WHERE id = ?;", statement: &stmt) else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, sqliteTransient)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return Self.timestamp(stmt, 0) }
        if let reason = stepMessage(rc) {
            // 读不到 created_at 时 upsert 会用 now 兜底，但 ON CONFLICT 不覆盖 created_at，旧值仍是安全的
            NSLog("AR: 读取 created_at 失败 id=\(id): \(reason)")
        }
        return nil
    }

    // MARK: 历史

    /// ⑤ history 原本只增不删：每次 upsert/delete/clean_expired/归档都插一行，全仓没有 DELETE，
    /// 跑一年就是上万行 —— recentHistory 变慢、库膨胀。
    /// 策略：启动清 90 天前的行，之后每 100 次写入截断到最近 2000 条（只删行，不动 ts/action/summary 语义）。
    private static let historyRetentionDays = 90.0
    private static let historyMaxRows: Int32 = 2000
    private static let historyPruneEvery = 100
    private var historyWrites = 0

    private func log(action: String, itemId: String?, summary: String) {
        var stmt: OpaquePointer?
        guard prepare("INSERT INTO history (ts,action,item_id,summary) VALUES (?,?,?,?);", statement: &stmt) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, (action as NSString).utf8String, -1, sqliteTransient)
        if let itemId { sqlite3_bind_text(stmt, 3, (itemId as NSString).utf8String, -1, sqliteTransient) } else { sqlite3_bind_null(stmt, 3) }
        sqlite3_bind_text(stmt, 4, (summary as NSString).utf8String, -1, sqliteTransient)
        // ① 原来 step 结果直接丢弃：历史少记一行不影响条目，但失败原因必须留痕
        let rc = sqlite3_step(stmt)
        if let reason = stepMessage(rc) {
            NSLog("AR: 操作历史写入失败 action=\(action) itemId=\(itemId ?? "nil"): \(reason)")
        } else {
            pruneHistory()
        }
    }

    /// 保留策略执行点：条数上限 + 时间上限一条 SQL 搞定，避免每次写历史都全表扫描。
    private func pruneHistory(force: Bool = false) {
        historyWrites += 1
        if !force, historyWrites % Self.historyPruneEvery != 0 { return }
        var stmt: OpaquePointer?
        guard prepare("""
        DELETE FROM history
         WHERE ts < ?1
            OR id NOT IN (SELECT id FROM history ORDER BY ts DESC, id DESC LIMIT ?2);
        """, statement: &stmt) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970 - Self.historyRetentionDays * 86400)
        sqlite3_bind_int(stmt, 2, Self.historyMaxRows)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE {
            let removed = sqlite3_changes(handle)
            if removed > 0 {
                NSLog("AR: history 清理 \(removed) 行（保留最近 \(Self.historyMaxRows) 条 / \(Self.historyRetentionDays) 天）")
            }
        } else if let reason = stepMessage(rc) {
            NSLog("AR: history 清理未完成: \(reason)")
        }
    }

    /// 读取最近 N 条操作历史（时间倒序）
    func recentHistory(limit: Int = 50) -> [(date: Date, action: String, summary: String)] {
        var result: [(Date, String, String)] = []
        var stmt: OpaquePointer?
        guard prepare("SELECT ts,action,summary FROM history ORDER BY ts DESC LIMIT ?;", statement: &stmt) else { return result }
        defer { sqlite3_finalize(stmt) }
        guard let boundLimit = int32(max(0, limit), field: "recentHistory limit") else {
            NSLog("AR: recentHistory limit 超出 Int32(\(limit))，返回空")
            return result
        }
        sqlite3_bind_int(stmt, 1, boundLimit)
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            let ts = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
            let action = Self.text(stmt, 1) ?? ""
            let summary = Self.text(stmt, 2) ?? ""
            result.append((ts, action, summary))
            rc = sqlite3_step(stmt)
        }
        if rc != SQLITE_DONE {   // ① 半读历史同样要留痕（只是展示，不参与删除决策）
            NSLog("AR: recentHistory 读取中断 \(stepMessage(rc) ?? "")，已取 \(result.count) 行")
        }
        return result
    }
}
