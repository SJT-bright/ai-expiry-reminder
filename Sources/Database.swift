import Foundation
import SQLite3

// MARK: - SQLite 持久化
// 手动条目 + 操作历史全部入库；重启/更新/崩溃都不会丢（WAL + 事务）。

final class Database {
    private var handle: OpaquePointer?
    private let path: URL

    init(dir: URL, filename: String = "data.sqlite") {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent(filename)
        guard sqlite3_open_v2(path.path, &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK else {
            NSLog("AR: 数据库打开失败 \(path.path)")
            handle = nil
            return
        }
        sqlite3_busy_timeout(handle, 2000)
        exec("PRAGMA journal_mode=WAL;")
        createSchema()
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
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
            alert_before REAL,
            used_percent REAL,
            group_id TEXT,
            created_at REAL,
            updated_at REAL
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_items_group ON items(group_id);")
        exec("""
        CREATE TABLE IF NOT EXISTS history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts REAL NOT NULL,
            action TEXT NOT NULL,
            item_id TEXT,
            summary TEXT
        );
        """)
    }

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            NSLog("AR: SQL 错误 \(sql.prefix(60))…: \(err.map { String(cString: $0) } ?? "未知")")
            if let err { free(err) }
        }
    }

    // MARK: 条目 CRUD

    @discardableResult
    func upsert(_ item: SubItem, action: String) -> Bool {
        let sql = """
        INSERT INTO items (id,name,vendor,kind,expires_at,repeat_hours,source,note,alert_before,used_percent,group_id,created_at,updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            name=excluded.name, vendor=excluded.vendor, kind=excluded.kind,
            expires_at=excluded.expires_at, repeat_hours=excluded.repeat_hours,
            source=excluded.source, note=excluded.note, alert_before=excluded.alert_before,
            used_percent=excluded.used_percent, group_id=excluded.group_id, updated_at=excluded.updated_at;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        let now = Date().timeIntervalSince1970
        let created = action == "add" ? now : (createdAt(of: item.id) ?? now)
        sqlite3_bind_text(stmt, 1, (item.id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (item.name as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (item.vendor as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (item.kind.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 5, item.expiresAt.timeIntervalSince1970)
        if let h = item.repeatHours { sqlite3_bind_double(stmt, 6, h) } else { sqlite3_bind_null(stmt, 6) }
        sqlite3_bind_text(stmt, 7, (item.source as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 8, (item.note as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 9, item.alertBeforeMinutes)
        if let u = item.usedPercent { sqlite3_bind_double(stmt, 10, u) } else { sqlite3_bind_null(stmt, 10) }
        if let g = item.groupID { sqlite3_bind_text(stmt, 11, (g as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(stmt, 11) }
        sqlite3_bind_double(stmt, 12, created)
        sqlite3_bind_double(stmt, 13, now)
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        if ok { log(action: action, itemId: item.id, summary: item.name) }
        return ok
    }

    @discardableResult
    func delete(id: String, action: String = "delete") -> Bool {
        let name = loadItems().first { $0.id == id }?.name ?? id
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "DELETE FROM items WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        if ok { log(action: action, itemId: id, summary: name) }
        return ok
    }

    @discardableResult
    func deleteGroup(_ groupID: String) -> Int {
        let members = loadItems().filter { $0.groupID == groupID }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "DELETE FROM items WHERE group_id = ?;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (groupID as NSString).utf8String, -1, nil)
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        if ok {
            log(action: "delete_group", itemId: groupID,
                summary: members.map { $0.name }.joined(separator: ", "))
        }
        return ok ? members.count : 0
    }

    func loadItems() -> [SubItem] {
        var result: [SubItem] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle,
            "SELECT id,name,vendor,kind,expires_at,repeat_hours,source,note,alert_before,used_percent,group_id FROM items ORDER BY expires_at;",
            -1, &stmt, nil) == SQLITE_OK else { return result }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let name = String(cString: sqlite3_column_text(stmt, 1))
            let vendor = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let kind = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "subscription"
            let expires = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            let repeatHours: Double? = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 5)
            let source = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "manual"
            let note = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? ""
            let alert = sqlite3_column_double(stmt, 8)
            let used: Double? = sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 9)
            let group: String? = sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 10))
            result.append(SubItem(id: id, name: name, vendor: vendor,
                                  kind: kind == "window" ? .window : .subscription,
                                  expiresAt: expires, repeatHours: repeatHours,
                                  source: source, note: note,
                                  alertBeforeMinutes: alert, usedPercent: used, groupID: group))
        }
        return result
    }

    private func createdAt(of id: String) -> Double? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT created_at FROM items WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_double(stmt, 0)
    }

    // MARK: 历史

    private func log(action: String, itemId: String?, summary: String) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle,
            "INSERT INTO history (ts,action,item_id,summary) VALUES (?,?,?,?);",
            -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, (action as NSString).utf8String, -1, nil)
        if let itemId { sqlite3_bind_text(stmt, 3, (itemId as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(stmt, 3) }
        sqlite3_bind_text(stmt, 4, (summary as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)
    }

    /// 读取最近 N 条操作历史（时间倒序）
    func recentHistory(limit: Int = 50) -> [(date: Date, action: String, summary: String)] {
        var result: [(Date, String, String)] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle,
            "SELECT ts,action,summary FROM history ORDER BY ts DESC LIMIT ?;",
            -1, &stmt, nil) == SQLITE_OK else { return result }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
            let action = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let summary = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            result.append((ts, action, summary))
        }
        return result
    }
}
