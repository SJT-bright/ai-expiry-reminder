import Foundation

func date(_ text: String) -> Date {
    let f = DateFormatter()
    f.timeZone = TimeZone(identifier: "Asia/Shanghai")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.date(from: text)!
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    print("PASS: \(message)")
}
let store = Store()
var reset = SubItem.manualDefault(name: "周重置")
reset.kind = .window
reset.repeatHours = 168
reset.expiresAt = date("2026-09-18 15:53")
store.upsertManual(reset)
store.rollManualWindows(now: date("2026-09-10 23:00"))
expect(store.manualItems.first!.expiresAt == date("2026-09-18 15:53"), "未来的首次重置不变")
store.rollManualWindows(now: date("2026-09-18 15:53"))
expect(store.manualItems.first!.expiresAt == date("2026-09-25 15:53"), "到期边界沿原日期加七天")
store.rollManualWindows(now: date("2026-10-07 20:00"))
expect(store.manualItems.first!.expiresAt == date("2026-10-09 15:53"), "跨多周离线仍保留15:53和星期五")
expect(Store().manualItems.first!.expiresAt == date("2026-10-09 15:53"), "持久化重载不改变重置时间")
var parent = SubItem.manualDefault(name: "ZCode")
parent.expiresAt = date("2026-10-04 00:00")
let weeks = parent.splitWeekly(from: date("2026-09-06 18:00"))
store.upsertManual(weeks)
var first = weeks[0]
first.expiresAt = date("2026-09-11 15:53")
store.upsertManual(first)
let expected = ["2026-09-11 15:53", "2026-09-18 15:53", "2026-09-25 15:53", "2026-10-02 15:53"]
for (i, week) in weeks.enumerated() {
    expect(store.manualItems.first { $0.id == week.id }!.expiresAt == date(expected[i]), "第\(i+1)周按修正后的第一周排列")
}

// ── 派生窗口删除一致性：用户删除父条目时，qreset 周重置窗口必须一并移除 ──
func makeCompanion(_ parent: SubItem, at: Date) -> SubItem {
    var c = SubItem.manualDefault(name: "\(parent.name)·周重置")
    c.id = "qreset:" + parent.id
    c.kind = .window
    c.repeatHours = 168
    c.groupID = parent.groupID ?? parent.id
    c.expiresAt = at
    return c
}

// 单条删除：父 + 周重置成对移除（日期用相对偏移，避免固定日期随真实时间过期）
var p1 = SubItem.manualDefault(name: "订阅A")
p1.expiresAt = Date().addingTimeInterval(30 * 86400)
store.upsertManual(p1)
store.upsertManual(makeCompanion(p1, at: Date().addingTimeInterval(7 * 86400)))
store.deleteManualWithDerived(p1.id)
expect(store.manualItems.first { $0.id == p1.id } == nil, "单条删除父订阅后父条目移除")
expect(store.manualItems.first { $0.id == "qreset:" + p1.id } == nil, "单条删除父订阅后周重置窗口一并移除")

// 批量删除（清理过期路径）：过期父+其窗口成对移除，在期条目及其窗口不受影响
var deadParent = SubItem.manualDefault(name: "过期订阅")
deadParent.expiresAt = Date().addingTimeInterval(-30 * 86400)
store.upsertManual(deadParent)
store.upsertManual(makeCompanion(deadParent, at: Date().addingTimeInterval(7 * 86400)))
var liveParent = SubItem.manualDefault(name: "在期订阅")
liveParent.expiresAt = Date().addingTimeInterval(60 * 86400)
store.upsertManual(liveParent)
store.upsertManual(makeCompanion(liveParent, at: Date().addingTimeInterval(7 * 86400)))
let expiredIDs = store.expiredManualItems(olderThan: 24).map { $0.id }
expect(expiredIDs.contains(deadParent.id), "过期父订阅进入清理名单")
expect(!expiredIDs.contains(liveParent.id), "在期订阅不进入清理名单")
store.deleteManualsWithDerived(expiredIDs)
expect(store.manualItems.first { $0.id == deadParent.id } == nil, "批量清理移除过期父订阅")
expect(store.manualItems.first { $0.id == "qreset:" + deadParent.id } == nil, "批量清理连带移除其周重置窗口")
expect(store.manualItems.first { $0.id == liveParent.id } != nil, "批量清理不影响在期订阅")
expect(store.manualItems.first { $0.id == "qreset:" + liveParent.id } != nil, "批量清理不影响在期订阅的周重置窗口")

// 组内「仅此条」：删除组成员连带其窗口，兄弟成员保留
var groupParent = SubItem.manualDefault(name: "周组源")
groupParent.expiresAt = date("2026-12-10 00:00")
let groupMembers = groupParent.splitWeekly(from: Date())
store.upsertManual(groupMembers)
store.upsertManual(makeCompanion(groupMembers[0], at: date("2026-09-14 00:00")))
store.deleteManualWithDerived(groupMembers[0].id)
expect(store.manualItems.first { $0.id == groupMembers[0].id } == nil, "组内仅此条移除该成员")
expect(store.manualItems.first { $0.id == "qreset:" + groupMembers[0].id } == nil, "组内仅此条连带移除其周重置窗口")
expect(store.manualItems.first { $0.id == groupMembers[1].id } != nil, "组内其他成员保留")

// ── 失败注入：只读数据目录 → SQLite 无法打开 → 写/删必须如实返回 false ──
let badDir = NSTemporaryDirectory() + "ar_readonly_\(UUID().uuidString)"
try? FileManager.default.createDirectory(atPath: badDir, withIntermediateDirectories: true)
try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: badDir)
let badStore = Store(environment: ["AR_DATA_DIR": badDir])
var probe = SubItem.manualDefault(name: "写失败探针")
expect(badStore.upsertManual(probe) == .parentFailed, "数据库不可写时 upsertManual 返回 parentFailed")
expect(badStore.deleteManual(id: probe.id) == false, "数据库不可写时 deleteManual 返回 false")
expect(badStore.upsertManual([probe]) == .parentFailed, "数据库不可写时批量 upsertManual 返回 parentFailed")
try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: badDir)

// ── 通知文案识别范围：额度重置窗口称「重置」，订阅与手动通用周期窗口称「到期」 ──
let resetProbe = SubItem(id: "qreset:探针", name: "探针·周重置", vendor: "探针",
                         kind: .window, expiresAt: date("2026-09-20 00:00"),
                         repeatHours: 168, source: "manual", note: "",
                         alertBeforeMinutes: 60, usedPercent: nil, groupID: nil)
let autoWindowProbe = SubItem(id: "auto:codex:codex:300", name: "Codex 通用·5小时窗口", vendor: "OpenAI",
                              kind: .window, expiresAt: date("2026-09-20 00:00"),
                              repeatHours: 5, source: "codex", note: "",
                              alertBeforeMinutes: 15, usedPercent: nil, groupID: nil)
var manualWindowProbe = SubItem.manualDefault(name: "月付续费日")
manualWindowProbe.kind = .window
manualWindowProbe.repeatHours = 720
expect(AlertEngine.composeMessage([resetProbe]).contains("重置（"), "周重置伴生窗口通知应称重置")
expect(AlertEngine.composeMessage([autoWindowProbe]).contains("重置（"), "官方额度窗口通知应称重置")
expect(!AlertEngine.composeMessage([manualWindowProbe]).contains("重置"), "手动通用周期窗口不得称重置")
expect(AlertEngine.composeMessage([manualWindowProbe]).contains("到期（"), "手动通用周期窗口通知仍称到期")
expect(AlertEngine.composeMessage([]).hasPrefix("⏳ AI到期提醒"), "空列表不崩溃且有标题")

// ── 写入三态：区分成功 / 父失败 / 已保存但关联同步失败（按 action 精确注入） ──
var tp = SubItem.manualDefault(name: "三态父")
tp.expiresAt = date("2026-12-01 00:00")
store.upsertManual(tp)
store.upsertManual(makeCompanion(tp, at: date("2026-09-14 00:00")))

// 全部成功：父 update + align_reset 都真实写库
store.upsertInjection = nil
tp.expiresAt = date("2026-12-02 00:00")
if case .success = store.upsertManual(tp) {} else {
    precondition(false, "正常写入应为 success")
}
expect(store.lastAlignmentFailures.isEmpty, "成功时无对齐失败证据")
expect(store.manualItems.first { $0.id == "qreset:" + tp.id }!.expiresAt == date("2026-09-15 00:00"), "对齐平移保持重置相位")

// 父失败：注入 update 失败 → parentFailed，数据不变
store.upsertInjection = { _, action in action == "update" ? false : nil }
tp.expiresAt = date("2026-12-03 00:00")
if case .parentFailed = store.upsertManual(tp) {} else {
    precondition(false, "父写失败应为 parentFailed")
}
expect(store.manualItems.first { $0.id == tp.id }!.expiresAt == date("2026-12-02 00:00"), "父失败时数据不变")

// 关联部分失败：注入 align_reset 失败 → savedWithAlignFailure 且证据可查
store.upsertInjection = { item, action in
    (action == "align_reset" && item.id == "qreset:" + tp.id) ? false : nil
}
tp.expiresAt = date("2026-12-03 00:00")
if case .savedWithAlignFailure(let fs) = store.upsertManual(tp) {
    expect(fs == ["align_reset:qreset:\(tp.id)"], "失败证据记录 align_reset:qreset id")
} else {
    precondition(false, "对齐失败应为 savedWithAlignFailure")
}
expect(store.manualItems.first { $0.id == tp.id }!.expiresAt == date("2026-12-03 00:00"), "部分失败时父条目已保存")
expect(store.manualItems.first { $0.id == "qreset:" + tp.id }!.expiresAt == date("2026-09-15 00:00"), "部分失败时伴生窗口未平移（证据保留）")
store.upsertInjection = nil

// 批量部分成功：3 条中注入 1 条失败 → partialSaved(written:2, failed:1)
let batchA = SubItem.manualDefault(name: "批量A")
let batchB = SubItem.manualDefault(name: "批量B")
let batchC = SubItem.manualDefault(name: "批量C")
store.upsertInjection = { item, _ in item.id == batchB.id ? false : nil }
if case .partialSaved(let written, let failed) = store.upsertManual([batchA, batchB, batchC]) {
    expect(written == 2 && failed == 1, "批量部分成功区分未写与已写")
} else {
    precondition(false, "批量部分失败应为 partialSaved")
}
expect(store.manualItems.contains { $0.id == batchA.id } && store.manualItems.contains { $0.id == batchC.id }, "批量成功的成员已写入")
expect(store.manualItems.contains { $0.id == batchB.id } == false, "批量失败的成员未写入")
store.upsertInjection = nil

// 批量全失败：全部未写入 → parentFailed（不得谎报部分成功）
store.upsertInjection = { _, _ in false }
if case .parentFailed = store.upsertManual([batchA, batchB, batchC]) {} else {
    precondition(false, "批量全失败应为 parentFailed")
}
store.upsertInjection = nil

// ── state.json 写盘失败检测：只读目录 → save() 后标志为 false（线程安全轮询） ──
let roDir = NSTemporaryDirectory() + "ar_ro_save_\(UUID().uuidString)"
try? FileManager.default.createDirectory(atPath: roDir, withIntermediateDirectories: true)
try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: roDir)
let roStore = Store(environment: ["AR_DATA_DIR": roDir])
var spin = 0
while roStore.lastSettingsWriteOK == nil && spin < 20 {
    roStore.save()
    usleep(100_000)
    spin += 1
}
expect(roStore.lastSettingsWriteOK == false, "写盘失败时 lastSettingsWriteOK 为 false")
try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roDir)
// 正常目录：写盘成功并清除旧失败
store.save()
spin = 0
while store.lastSettingsWriteOK != true && spin < 20 {
    usleep(100_000)
    spin += 1
}
expect(store.lastSettingsWriteOK == true, "写盘成功清除旧失败状态")

// ── 固定日历重置模型：每月固定日 / 每周固定星期 / 订阅日锚定月 ──
func makeCal(_ name: String, rule: ResetRule, param: Int, expiry: Date) -> SubItem {
    var it = SubItem.manualDefault(name: name)
    it.kind = .window
    it.resetRule = rule
    it.resetParam = param
    it.expiresAt = expiry
    return it
}
// 每月 17 号：9/18（节点已过）→ 10/17；离线跨过 10/17 → 直接 12/17（不累积）
var cal17 = makeCal("月17探针", rule: .calendarMonth, param: 17, expiry: date("2026-09-17 00:00"))
store.upsertManual(cal17)
store.rollManualWindows(now: date("2026-09-18 12:00"))
expect(store.manualItems.first { $0.id == cal17.id }!.expiresAt == date("2026-10-17 00:00"), "月17：节点已过滚到下月17号")
store.rollManualWindows(now: date("2026-11-20 12:00"))
expect(store.manualItems.first { $0.id == cal17.id }!.expiresAt == date("2026-12-17 00:00"), "月17：离线跨周期不累积，跳到下一个17号")

// 31 号在小月钳到月末：2 月→2/28 之后滚到 3/31
var cal31 = makeCal("月31探针", rule: .calendarMonth, param: 31, expiry: date("2026-01-31 00:00"))
store.upsertManual(cal31)
store.rollManualWindows(now: date("2026-02-15 12:00"))
expect(store.manualItems.first { $0.id == cal31.id }!.expiresAt == date("2026-02-28 00:00"), "31号在小月钳到月末（2/28）")
store.rollManualWindows(now: date("2026-03-15 12:00"))
expect(store.manualItems.first { $0.id == cal31.id }!.expiresAt == date("2026-03-31 00:00"), "大月恢复31号")

// 每周一（param=1）：周三 → 下一个周一
var calMon = makeCal("每周一探针", rule: .calendarWeek, param: 1, expiry: date("2026-09-14 00:00"))
store.upsertManual(calMon)
store.rollManualWindows(now: date("2026-09-16 12:00"))
expect(store.manualItems.first { $0.id == calMon.id }!.expiresAt == date("2026-09-21 00:00"), "calendarWeek：滚到下一个周一 00:00")

// 订阅日锚定月（param=订阅日15号）：9/16 → 10/15
var anchor15 = makeCal("订阅日15探针", rule: .anchorMonth, param: 15, expiry: date("2026-09-15 00:00"))
store.upsertManual(anchor15)
store.rollManualWindows(now: date("2026-09-16 12:00"))
expect(store.manualItems.first { $0.id == anchor15.id }!.expiresAt == date("2026-10-15 00:00"), "anchorMonth：滚到下个订阅日 00:00")

// 持久化往返：reset_rule/reset_param 入库后可读回
let reloaded = Store()
let calBack = reloaded.manualItems.first { $0.id == cal17.id }
expect(calBack?.resetRule == .calendarMonth && calBack?.resetParam == 17, "reset 规则/参数持久化往返")

// nextCalendarReset 纯计算：月中未到节点时返回本月节点
var midMonth = makeCal("月中探针", rule: .calendarMonth, param: 25, expiry: date("2026-09-25 00:00"))
expect(midMonth.nextCalendarReset(after: date("2026-09-10 08:00")) == date("2026-09-25 00:00"), "本月节点未到即为本月节点")

// ── 滚动长周期（1~2 个月、3 个月以上）：跨月推进正确 ──
var roll30 = SubItem.manualDefault(name: "滚动30天探针")
roll30.kind = .window
roll30.repeatHours = 24 * 30
roll30.expiresAt = date("2026-09-10 00:00")
store.upsertManual(roll30)
store.rollManualWindows(now: date("2026-10-05 12:00"))
expect(store.manualItems.first { $0.id == roll30.id }!.expiresAt == date("2026-10-10 00:00"), "滚动30天：10/05 未到节点不变")
store.rollManualWindows(now: date("2026-11-20 12:00"))
expect(store.manualItems.first { $0.id == roll30.id }!.expiresAt == date("2026-12-09 00:00"), "滚动30天：跨月推进保持30天相位（11/20→12/09）")
var roll90 = SubItem.manualDefault(name: "滚动90天探针")
roll90.kind = .window
roll90.repeatHours = 24 * 90
roll90.expiresAt = date("2026-08-01 00:00")
store.upsertManual(roll90)
store.rollManualWindows(now: date("2026-11-01 12:00"))
expect(store.manualItems.first { $0.id == roll90.id }!.expiresAt == date("2027-01-28 00:00"), "滚动90天：8/1起90天相位推进到2027/1/28")

// ── 自动收起抑制器：模态期间抑制，结束后按光标位置恢复 ──
var suppressor = AutoCollapseSuppressor()
expect(suppressor.shouldSchedule, "初始状态允许调度")
suppressor.begin()
expect(suppressor.isSuppressed, "begin 后处于抑制状态")
expect(suppressor.shouldSchedule == false, "抑制期间不启动自动收起定时")
expect(suppressor.end(cursorInsidePanel: false) == true, "光标在面板外：结束抑制后立即恢复定时")
expect(suppressor.shouldSchedule, "结束抑制后恢复可调度")
suppressor.begin()
expect(suppressor.end(cursorInsidePanel: true) == false, "光标在面板内：结束抑制不立即恢复（移出时自然重挂）")
expect(suppressor.isSuppressed == false, "结束后不再抑制，正常悬停不受影响")

// ── 边界补强：固定时区（Asia/Shanghai）下的对齐/钳制/星期语义 ──
var shanghai = Calendar(identifier: .gregorian)
shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!

// 今天即该星期几：周一 10:00 → 下周一 00:00（本周 00:00 已过即失去意义）
var mondayProbe = makeCal("周一探针", rule: .calendarWeek, param: 1, expiry: date("2026-09-14 00:00"))
expect(mondayProbe.nextCalendarReset(after: date("2026-09-14 10:00"), calendar: shanghai) == date("2026-09-21 00:00"), "周一当天已过 00:00 → 下周一")
expect(mondayProbe.nextCalendarReset(after: date("2026-09-14 00:00"), calendar: shanghai) == date("2026-09-21 00:00"), "周一 00:00 整即视为已重置 → 下周一")

// anchorMonth 月末钳制（订阅日 31 号）：小月 2/28，大月 3/31
var anchor31 = makeCal("订阅日31", rule: .anchorMonth, param: 31, expiry: date("2026-01-31 00:00"))
expect(anchor31.nextCalendarReset(after: date("2026-02-15 10:00"), calendar: shanghai) == date("2026-02-28 00:00"), "anchorMonth 31号小月钳到 2/28")
expect(anchor31.nextCalendarReset(after: date("2026-03-15 10:00"), calendar: shanghai) == date("2026-03-31 00:00"), "anchorMonth 31号大月恢复 3/31")

// calendarWeek 离线跨多周：不累积，直接下一个周一
var weekOffline = makeCal("周一离线", rule: .calendarWeek, param: 1, expiry: date("2026-09-14 00:00"))
expect(weekOffline.nextCalendarReset(after: date("2026-10-20 12:00"), calendar: shanghai) == date("2026-10-26 00:00"), "calendarWeek 离线跨多周不累积")

// ── 重置模型自动推断：购买/到期/最近重置 → 类型判定（降低选择成本） ──
// 用户例①：9/15 购买、12/14 到期、最近重置 9/17 00:00 → 官方固定每月 17 号（与购买日无关）
let infer1 = ResetInference.infer(purchase: date("2026-09-15 10:05"),
                                  expiry: date("2026-12-14 17:29"),
                                  lastReset: date("2026-09-17 00:00"))
expect(infer1.rule == .calendarMonth && infer1.param == 17, "推断①：9/17 00:00 → 官方固定每月17号")
// 订阅日锚定：最近重置的“几号”== 购买日的“几号” → anchorMonth
let infer2 = ResetInference.infer(purchase: date("2026-09-15 10:05"),
                                  expiry: date("2026-11-15 10:05"),
                                  lastReset: date("2026-10-15 00:00"))
expect(infer2.rule == .anchorMonth && infer2.param == 15, "推断②：重置日=订阅日15号 → anchorMonth")
// 购买锚定滚动（4 期周额度）：同刻 + 购买/最近重置都在 7 天网格 → rolling
let infer3 = ResetInference.infer(purchase: date("2026-09-15 10:05"),
                                  expiry: date("2026-10-13 10:05"),
                                  lastReset: date("2026-09-29 10:05"))
expect(infer3.rule == .rolling, "推断③：购买同刻 7 天网格 → 购买锚定滚动")
// 千问式：最近重置为周一 00:00 且到期日同为周一 → calendarWeek(1=周一)
let infer4 = ResetInference.infer(purchase: date("2026-09-16 10:05"),
                                  expiry: date("2026-12-14 10:05"),
                                  lastReset: date("2026-09-21 00:00"))
expect(infer4.rule == .calendarWeek && infer4.param == 1, "推断④：周一00:00 → calendarWeek")
// 保底：杂乱时间 → 按最近重置滚动
let infer5 = ResetInference.infer(purchase: date("2026-09-16 08:00"),
                                  expiry: date("2026-12-16 08:00"),
                                  lastReset: date("2026-09-20 13:00"))
expect(infer5.rule == .rolling, "推断⑤：杂乱时间保底滚动")
