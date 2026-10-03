import Foundation
import SQLite3

func check(_ condition: Bool, _ message: String) { guard condition else { fatalError(message) }; print("PASS: \(message)") }
func root() throws -> URL { let u=FileManager.default.temporaryDirectory.appendingPathComponent("expiry-migration-"+UUID().uuidString);try FileManager.default.createDirectory(at:u,withIntermediateDirectories:true);return u }
func encode(_ value: AppState = AppState()) throws -> [String:Any] { let e=JSONEncoder();e.dateEncodingStrategy = .iso8601;return try JSONSerialization.jsonObject(with:e.encode(value)) as! [String:Any] }
func legacyRow(_ name: String) throws -> [String:Any] { var i=SubItem.manualDefault(name:name);i.expiresAt=Date().addingTimeInterval(90*86400);let e=JSONEncoder();e.dateEncodingStrategy = .iso8601;return try JSONSerialization.jsonObject(with:e.encode(i)) as! [String:Any] }
func writeLegacy(_ base: URL,_ rows: Any) throws -> URL { let dir=base.appendingPathComponent("AI到期提醒");try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);var state=try encode();state["manualItems"]=rows;state["syntheticUnknownField"]="preserve";let file=dir.appendingPathComponent("state.json");try JSONSerialization.data(withJSONObject:state).write(to:file);return file }
func read(_ file: URL) throws -> [String:Any] { try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any] }
func sql(_ path: URL,_ query: String) throws { var h: OpaquePointer?;check(sqlite3_open(path.path,&h)==SQLITE_OK,"synthetic database opens");defer{sqlite3_close(h)};check(sqlite3_exec(h,query,nil,nil,nil)==SQLITE_OK,"synthetic fault trigger applies") }
func waitIO(){RunLoop.current.run(until:Date().addingTimeInterval(0.3))}

// Corrupt database + subsequent settings save cannot remove the legacy key.
do {
 let base=try root();defer{try? FileManager.default.removeItem(at:base)}
 let row=try legacyRow("audit-corrupt");let file=try writeLegacy(base,[row]);let before=try Data(contentsOf:file)
 try Data("NOT-A-SQLITE-DATABASE".utf8).write(to:base.appendingPathComponent("AI到期提醒/data.sqlite"))
 let store=Store(environment:["AR_DATA_DIR":base.path]);waitIO()
 check(store.manualItems.isEmpty,"corrupt SQLite imports zero rows")
 check(try Data(contentsOf:file)==before,"failed migration preserves original JSON bytes")
 store.save();waitIO()
 check((try read(file)["manualItems"] as? [Any])?.count==1,"later settings save preserves failed legacy records")
}
// A later row failure must roll back the earlier row too, then permit a retry.
do {
 let base=try root();defer{try? FileManager.default.removeItem(at:base)}
 let rows=[try legacyRow("audit-first"),try legacyRow("audit-blocked")];let file=try writeLegacy(base,rows);let before=try Data(contentsOf:file)
 let dir=base.appendingPathComponent("AI到期提醒");do{_ = Database(dir:dir)}
 try sql(dir.appendingPathComponent("data.sqlite"),"CREATE TRIGGER migration_fail BEFORE INSERT ON items WHEN NEW.name='audit-blocked' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END;")
 do{let store=Store(environment:["AR_DATA_DIR":base.path]);check(store.manualItems.isEmpty,"second-row failure rolls back entire migration");check(try Data(contentsOf:file)==before,"rollback retains complete original legacy JSON")}
 try sql(dir.appendingPathComponent("data.sqlite"),"DROP TRIGGER migration_fail;")
 let retry=Store(environment:["AR_DATA_DIR":base.path]);check(retry.manualItems.count==2,"failed migration can retry successfully")
 check(try read(file)["manualItems"]==nil,"legacy key removed only after verified commit")
 check(try read(file)["syntheticUnknownField"] as? String=="preserve","cleanup preserves unknown original fields")
 let reopened=Store(environment:["AR_DATA_DIR":base.path]);check(reopened.manualItems.count==2,"successful migration survives restart without duplicate items")
}
// Invalid row never produces a partial migration; settings save retains it.
do {
 let base=try root();defer{try? FileManager.default.removeItem(at:base)}
 let file=try writeLegacy(base,[try legacyRow("audit-valid"),["id":"audit-invalid"]]);let store=Store(environment:["AR_DATA_DIR":base.path]);store.save();waitIO()
 check(store.manualItems.isEmpty,"malformed row stops migration before all writes")
 check((try read(file)["manualItems"] as? [Any])?.count==2,"settings save retains valid and malformed legacy rows")
}
// Already committed IDs must not overwrite later edits on cleanup retry.
do {
 let base=try root();defer{try? FileManager.default.removeItem(at:base)}
 let row=try legacyRow("audit-old");let file=try writeLegacy(base,[row]);let dir=base.appendingPathComponent("AI到期提醒")
 let data=try JSONSerialization.data(withJSONObject:row);let d=JSONDecoder();d.dateDecodingStrategy = .iso8601;var item=try d.decode(SubItem.self,from:data);item.name="audit-newer-edit"
 do{let db=Database(dir:dir);check(db.upsert(item,action:"import"),"synthetic already-committed item persists")}
 let store=Store(environment:["AR_DATA_DIR":base.path]);check(store.manualItems.first?.name=="audit-newer-edit","cleanup retry preserves newer database edit")
 check(try read(file)["manualItems"]==nil,"idempotent retry cleans legacy JSON")
}
print("MIGRATION REGRESSIONS PASS")
