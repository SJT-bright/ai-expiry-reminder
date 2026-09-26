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

// ── 重置窗口识别：额度重置窗口与手动通用周期窗口的语义区分 ──
let resetProbe = SubItem(id: "qreset:探针", name: "探针·周重置", vendor: "探针",
                         kind: .window, expiresAt: date("2026-09-20 00:00"),
                         repeatHours: 168, source: "manual", note: "",
                         usedPercent: nil, groupID: nil)
let autoWindowProbe = SubItem(id: "auto:codex:codex:300", name: "Codex 通用·5小时窗口", vendor: "OpenAI",
                              kind: .window, expiresAt: date("2026-09-20 00:00"),
                              repeatHours: 5, source: "codex", note: "",
                              usedPercent: nil, groupID: nil)
var manualWindowProbe = SubItem.manualDefault(name: "月付续费日")
manualWindowProbe.kind = .window
manualWindowProbe.repeatHours = 720
expect(resetProbe.isQuotaResetWindow, "qreset 伴生窗口识别为重置窗口")
expect(autoWindowProbe.isQuotaResetWindow, "官方额度窗口识别为重置窗口")
expect(!manualWindowProbe.isQuotaResetWindow, "手动通用周期窗口不算重置窗口")

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

// ── 修复回归：previousCalendarReset 月末钳制回退（从本月 param 日重构，未到则取上月） ──
var monthEndProbe = makeCal("月末回退探针", rule: .calendarMonth, param: 31, expiry: date("2026-01-31 00:00"))
expect(monthEndProbe.previousCalendarReset(before: date("2026-02-15 10:00")) == date("2026-01-31 00:00"), "月末钳制回退：2月中回退31号得 1/31 而非 1/28")
expect(monthEndProbe.previousCalendarReset(before: date("2026-03-05 10:00")) == date("2026-02-28 00:00"), "月末钳制回退：3月初回退得小月钳制日 2/28")

// ── 修复回归：Fmt.countdown 过期 0 分瑕疵 ──
expect(Fmt.countdown(until: Date().addingTimeInterval(-30), now: Date()) == "已过期", "countdown：过期不足 1 分钟显示「已过期」")
expect(Fmt.countdown(until: Date().addingTimeInterval(-90), now: Date()) == "已过期1分", "countdown：过期 1.5 分钟显示 1 分")

// ── 周期档位推断：购买→到期间隔 ──
expect(ResetInference.inferPeriodHours(purchase: date("2026-09-01 10:00"), expiry: date("2026-09-08 09:30")) == 168, "inferPeriodHours：167.5h 命中 168 档（±6h 容差）")
expect(ResetInference.inferPeriodHours(purchase: date("2026-09-01 10:00"), expiry: date("2026-09-05 14:00")) == nil, "inferPeriodHours：100h 不命中任何档位")

// ── 厂商知识库：反向识别 + 机器可读候选 ──
expect(VendorResetKnowledge.vendor(for: "我的 Codex 助手") == "OpenAI", "vendor(for:)：名称含 Codex 反推 OpenAI")
expect(VendorResetKnowledge.vendor(for: "神秘小站") == nil, "vendor(for:)：无法识别返回 nil")
let codexCand = VendorResetKnowledge.bestCandidate(for: "OpenAI")
expect(codexCand?.rule == .rolling && codexCand?.repeatHours == 5, "bestCandidate(OpenAI)：5 小时滚动窗口")
expect(VendorResetKnowledge.bestCandidate(for: "中转站") == nil, "bestCandidate：无把握厂商返回 nil")
expect(VendorResetKnowledge.hint(for: "OpenAI") != nil, "hint(for:) 保持可用")

// ── 推断结果携带周期；全量推断优先级 ──
expect(infer1.repeatHours == nil, "推断①日历模式 repeatHours 为 nil")
expect(infer3.repeatHours == 168, "推断③购买锚定滚动携带 repeatHours=168")
let fullHist = ResetInference.infer(name: "探针", vendor: "OpenAI", expiresAt: date("2026-12-14 00:00"), purchaseAt: nil,
                                    history: (rule: .calendarMonth, param: 17, repeatHours: nil))
expect(fullHist.rule == .calendarMonth && fullHist.param == 17, "全量推断：历史继承优先于厂商知识库")
let fullCand = ResetInference.infer(name: "探针", vendor: "OpenAI", expiresAt: date("2026-12-14 00:00"), purchaseAt: nil, history: nil)
expect(fullCand.rule == .rolling && fullCand.repeatHours == 5, "全量推断：无历史时用厂商知识库（OpenAI 5h）")
let fullPeriod = ResetInference.infer(name: "探针", vendor: "神秘", expiresAt: date("2026-09-08 10:00"), purchaseAt: date("2026-09-01 10:00"), history: nil)
expect(fullPeriod.rule == .rolling && fullPeriod.repeatHours == 168, "全量推断：购买→到期间隔推 168h")
let fullFallback = ResetInference.infer(name: "探针", vendor: "神秘", expiresAt: date("2026-12-20 08:13"), purchaseAt: nil, history: nil)
expect(fullFallback.rule == .rolling && fullFallback.repeatHours == 168, "全量推断：保底 rolling 7 天")

// ── 伴生窗口工厂：rolling / 日历两种模式 ──
var factoryParent = SubItem.manualDefault(name: "工厂探针")
factoryParent.expiresAt = date("2026-12-01 00:00")
let factoryRolling = ResetWindowFactory.companion(for: factoryParent, rule: .rolling, param: 7, repeatHours: 168, now: date("2026-09-17 12:00"))
expect(factoryRolling.id == "qreset:" + factoryParent.id, "伴生工厂：id = qreset:父id")
expect(factoryRolling.kind == .window && factoryRolling.resetRule == .rolling
       && factoryRolling.repeatHours == 168 && factoryRolling.resetParam == 7, "伴生工厂：rolling 字段")
expect(factoryRolling.expiresAt == date("2026-12-08 00:00"), "伴生工厂：首次锚点沿填写的到期日加周期")
expect(factoryRolling.name == "工厂探针·周期重置", "伴生工厂：命名沿用父条目")
let factoryCal = ResetWindowFactory.companion(for: factoryParent, rule: .calendarMonth, param: 17, repeatHours: nil, now: date("2026-09-18 12:00"))
expect(factoryCal.resetRule == .calendarMonth && factoryCal.resetParam == 17 && factoryCal.repeatHours == nil, "伴生工厂：日历字段")
expect(factoryCal.expiresAt == date("2026-10-17 00:00"), "伴生工厂：日历模式取下一个节点")
expect(factoryCal.note.contains("每月 17 日 00:00 重置额度"), "伴生工厂：日历文案与 syncQuotaReset 一致")

// ── saveInferred：已知厂商自动生成伴生窗口 + 空名称自动命名 ──
let openaiResult = store.saveInferred(name: "", vendor: "OpenAI", expiresAt: date("2026-12-01 12:00"), purchaseAt: date("2026-09-01 12:00"))
expect(openaiResult.saved, "saveInferred：已知厂商写入成功")
let openaiParent = store.manualItems.first { $0.vendor == "OpenAI" && $0.kind == .subscription }
expect(openaiParent != nil, "saveInferred：父条目落库")
expect(openaiParent?.name == "OpenAI·周期额度", "saveInferred：空名称自动命名（厂商+·周期额度）")
expect(openaiParent?.purchaseAt == date("2026-09-01 12:00"), "saveInferred：purchaseAt 落库")
let openaiCompanion = store.manualItems.first { $0.id == SubItem.quotaResetId(for: openaiParent!.id) }
expect(openaiCompanion?.kind == .window && openaiCompanion?.repeatHours == 5 && openaiCompanion?.resetRule == .rolling, "saveInferred：OpenAI 自动生成 5h 滚动伴生窗口")
expect(openaiParent!.note.contains("重置节奏来源"), "saveInferred：厂商知识命中时 note 注明来源")

// 空供应商：经 vendor(for:) 反推
let claudeResult = store.saveInferred(name: "Claude 编程月卡", vendor: "   ", expiresAt: date("2026-11-20 00:00"), purchaseAt: nil)
expect(claudeResult.saved, "saveInferred：空供应商写入成功")
let claudeParent = store.manualItems.first { $0.name == "Claude 编程月卡" }
expect(claudeParent?.vendor == "Anthropic", "saveInferred：空供应商经名称反推为 Anthropic")
expect(claudeParent?.purchaseAt != nil, "saveInferred：无购买时间时按已知周期兜底回推记录")

// 未分类厂商：不凭空生成伴生窗口
let unknownResult = store.saveInferred(name: "神秘服务", vendor: "未分类", expiresAt: date("2026-12-15 00:00"), purchaseAt: nil)
expect(unknownResult.saved, "saveInferred：未分类厂商写入成功")
expect(!store.manualItems.contains { $0.id.hasPrefix("qreset:") && $0.name.contains("神秘服务") }, "saveInferred：未分类厂商不生成伴生窗口")
expect(store.manualItems.first { $0.name == "神秘服务" }?.vendor == "未分类", "saveInferred：未识别厂商归入未分类")

// 全空输入：未分类 + 自动命名「·订阅」
let bareResult = store.saveInferred(name: "", vendor: nil, expiresAt: date("2026-12-31 00:00"), purchaseAt: nil)
expect(bareResult.saved, "saveInferred：全空输入写入成功")
expect(store.manualItems.contains { $0.name == "未分类·订阅" && $0.vendor == "未分类" }, "saveInferred：全空输入自动命名 未分类·订阅")

// lastResetModel：同供应商最近窗口（大小写不敏感）
expect(store.lastResetModel(vendor: "openai")?.repeatHours == 5, "lastResetModel：同供应商最近窗口（大小写不敏感）")
expect(store.lastResetModel(vendor: "不存在厂商") == nil, "lastResetModel：无匹配返回 nil")

// ── updateManual：rolling 伴生平移 / 日历伴生不平移 ──
var openaiEdit = openaiParent!
let openaiPrev = openaiEdit.expiresAt
let companionBefore = store.manualItems.first { $0.id == SubItem.quotaResetId(for: openaiEdit.id) }!.expiresAt
openaiEdit.expiresAt = openaiPrev.addingTimeInterval(2 * 86400)
expect(store.updateManual(openaiEdit, previousExpiry: openaiPrev).saved, "updateManual：编辑写入成功")
expect(store.manualItems.first { $0.id == SubItem.quotaResetId(for: openaiEdit.id) }!.expiresAt
       == companionBefore.addingTimeInterval(2 * 86400), "updateManual：rolling 伴生锚点同步平移")

let qwenResult = store.saveInferred(name: "", vendor: "通义千问", expiresAt: date("2026-12-10 00:00"), purchaseAt: nil)
expect(qwenResult.saved, "saveInferred：千问写入成功")
let qwenParent = store.manualItems.first { $0.vendor == "通义千问" && $0.kind == .subscription }!
let qwenCompanionBefore = store.manualItems.first { $0.id == SubItem.quotaResetId(for: qwenParent.id) }
expect(qwenCompanionBefore?.resetRule == .calendarWeek && qwenCompanionBefore?.resetParam == 1, "saveInferred：千问伴生为每周一重置")
var qwenEdit = qwenParent
let qwenPrev = qwenEdit.expiresAt
qwenEdit.expiresAt = qwenPrev.addingTimeInterval(3 * 86400)
_ = store.updateManual(qwenEdit, previousExpiry: qwenPrev)
expect(store.manualItems.first { $0.id == SubItem.quotaResetId(for: qwenParent.id) }!.expiresAt == qwenCompanionBefore!.expiresAt, "updateManual：日历模式伴生不平移（独立于到期日）")

// ── saveWindow：显式周期额度（周额度界定 + 倒推窗口起点） ──
let weeklyExpiry = date("2026-12-07 00:00")
expect(store.saveWindow(name: "", vendor: "其他", expiresAt: weeklyExpiry, repeatHours: 168).saved, "saveWindow：周额度写入成功")
let weeklyWindow = store.manualItems.first { $0.name == "其他·周期额度" }
expect(weeklyWindow?.kind == .window && weeklyWindow?.repeatHours == 168, "saveWindow：周额度窗口自动命名并按 168h 滚动")
expect(weeklyWindow?.purchaseAt == weeklyExpiry.addingTimeInterval(-168 * 3600), "saveWindow：窗口起点倒推 = 到期 − 周期")
expect(weeklyWindow?.resetRule == .rolling && weeklyWindow?.resetParam == 7, "saveWindow：滚动规则与天数参数齐备")
let fiveHourExpiry = date("2026-12-07 18:00")
expect(store.saveWindow(name: "短周期卡", vendor: nil, expiresAt: fiveHourExpiry, repeatHours: 5).saved, "saveWindow：5小时窗口写入成功")
let fiveHour = store.manualItems.first { $0.name == "短周期卡" }
expect(fiveHour?.vendor == "未分类" && fiveHour?.repeatHours == 5 && fiveHour?.resetParam == nil, "saveWindow：非整天数周期省略 resetParam")

// 订阅转周期窗口：冗余伴生自动清理
var convert = SubItem.manualDefault(name: "转换探针", vendor: "xAI")
convert.expiresAt = date("2026-12-20 00:00")
store.upsertManual(convert)
store.upsertManual(makeCompanion(convert, at: date("2026-12-27 00:00")))
expect(store.manualItems.contains { $0.id == SubItem.quotaResetId(for: convert.id) }, "转换前置：伴生窗口存在")
var converted = convert
converted.kind = .window
converted.repeatHours = 168
converted.resetRule = .rolling
converted.resetParam = 7
expect(store.updateManual(converted, previousExpiry: convert.expiresAt).saved, "订阅转周期：编辑写入成功")
expect(store.manualItems.first { $0.id == SubItem.quotaResetId(for: convert.id) } == nil, "订阅转周期：冗余伴生窗口被清理")

// ── saveWeeklySplit：官方周额度节奏（第k/n周，独立于订阅到期） ──
// 用户场景：9/17 买 Grok，订阅到期 10/17，首次重置 9/20 → 每周一档共 4 轮，10/18 叠不满被排除
let splitExpiry = date("2026-10-17 00:00")
expect(store.saveWeeklySplit(name: "Grok 月卡", vendor: "xAI", expiry: splitExpiry,
                             firstReset: date("2026-09-20 00:00")).saved, "saveWeeklySplit：写入成功")
let splitMembers = store.manualItems
    .filter { $0.name.hasPrefix("Grok 月卡·第") }
    .sorted { $0.expiresAt < $1.expiresAt }
expect(splitMembers.count == 4, "saveWeeklySplit：9/20 起每 7 天到 10/17 共 4 轮（10/18 叠不满被排除）")
expect(splitMembers.first?.name == "Grok 月卡·第1/4周" && splitMembers.first?.expiresAt == date("2026-09-20 00:00"),
       "saveWeeklySplit：首周 9/20 命名 第1/4周")
expect(splitMembers.last?.name == "Grok 月卡·第4/4周" && splitMembers.last?.expiresAt == date("2026-10-11 00:00"),
       "saveWeeklySplit：末周 10/11，叠不满订阅到期")
expect(Set(splitMembers.compactMap(\.groupID)).count == 1, "saveWeeklySplit：组成员共享 groupID")
// 升级转换：replacing 移除原单条（订阅升级为周额度组）
var upgrade = SubItem.manualDefault(name: "升级探针", vendor: "xAI")
upgrade.expiresAt = date("2026-11-30 00:00")
store.upsertManual(upgrade)
expect(store.saveWeeklySplit(name: "升级探针", vendor: "xAI", expiry: date("2026-11-30 00:00"),
                             firstReset: date("2026-10-20 00:00"), replacing: upgrade.id).saved,
       "saveWeeklySplit：升级写入成功")
expect(store.manualItems.first { $0.id == upgrade.id } == nil, "saveWeeklySplit：replacing 原单条被移除")
expect(store.manualItems.contains { $0.name == "升级探针·第1/6周" }, "saveWeeklySplit：升级后生成周组（10/20 起共 6 轮）")
expect(store.manualItems.first { $0.name == "Grok 月卡·第1/4周" }?.note.contains("白嫖") == true,
       "saveWeeklySplit：note 携带计算性建议")

// ── QuotaAdvice：排期建议（首短轮快点用 / 末轮白嫖 / 续买再等 leftover 天） ──
let adviceNow = date("2026-09-22 12:00")
let advicePlan = QuotaAdvice.weeklyPlan(expiry: date("2026-10-26 00:00"),
                                        firstReset: date("2026-09-25 00:00"), now: adviceNow)
expect(advicePlan.resets.count == 5 && advicePlan.resets.last == date("2026-10-23 00:00"),
       "QuotaAdvice：自动填补全部重置时点（9/25 起共 5 轮，末轮 10/23）")
expect(advicePlan.advice.contains { $0.contains("快点用") && $0.contains("3 天") },
       "QuotaAdvice：首轮只有 3 天 → 提示快点用")
expect(advicePlan.advice.contains { $0.contains("白嫖") && $0.contains("3 天") && $0.contains("再等 4 天") },
       "QuotaAdvice：末轮 3 天白嫖一周额度 → 续买建议再等 4 天")
let zeroTail = QuotaAdvice.weeklyPlan(expiry: date("2026-10-30 00:00"),
                                      firstReset: date("2026-09-25 00:00"), now: adviceNow)
expect(zeroTail.resets.count == 6 && zeroTail.advice.contains { $0.contains("重置即到期") },
       "QuotaAdvice：末轮重置即到期给出专项提示")
expect(QuotaAdvice.weeklyPlan(expiry: date("2026-09-19 00:00"),
                              firstReset: date("2026-09-25 00:00")).advice.first?.contains("早于") == true,
       "QuotaAdvice：锚点晚于到期给出错误提示")

// ── repeatHours 清洗：防病态滚动循环 ──
var dirtyHalf = SubItem.manualDefault(name: "半点窗口")
dirtyHalf.kind = .window
dirtyHalf.repeatHours = 0.5
store.upsertManual(dirtyHalf)
expect(store.manualItems.first { $0.id == dirtyHalf.id }?.repeatHours == 1, "repeatHours 0.5 钳到 1")
var dirtyNeg = SubItem.manualDefault(name: "负周期窗口")
dirtyNeg.kind = .window
dirtyNeg.repeatHours = -5
store.upsertManual(dirtyNeg)
expect(store.manualItems.first { $0.id == dirtyNeg.id }?.repeatHours == nil, "repeatHours -5 置 nil")
var dirtyZero = SubItem.manualDefault(name: "零周期窗口")
dirtyZero.kind = .window
dirtyZero.repeatHours = 0
store.upsertManual(dirtyZero)
expect(store.manualItems.first { $0.id == dirtyZero.id }?.repeatHours == nil, "repeatHours 0 置 nil")

// ── 归档生命周期：archiveExpiredSubscriptions / displaySorted / purgeArchived ──
var oldSub = SubItem.manualDefault(name: "老过期订阅")
oldSub.expiresAt = Date().addingTimeInterval(-10 * 86400)
store.upsertManual(oldSub)
store.upsertManual(makeCompanion(oldSub, at: Date().addingTimeInterval(7 * 86400)))
var freshSub = SubItem.manualDefault(name: "在期订阅B")
freshSub.expiresAt = Date().addingTimeInterval(10 * 86400)
store.upsertManual(freshSub)
store.archiveExpiredSubscriptions(olderThan: 3)
expect(store.manualItems.first { $0.id == oldSub.id }?.isArchived == true, "过期超过 3 天的手动订阅被归档")
expect(store.manualItems.first { $0.id == "qreset:" + oldSub.id }?.isArchived == true, "伴生重置窗口随父一并归档，不留孤儿窗口")
expect(store.manualItems.first { $0.id == freshSub.id }?.isArchived == false, "在期订阅不受归档影响")
let sorted = SubItem.displaySorted(store.manualItems, now: Date())
expect(sorted.last?.id == oldSub.id, "displaySorted：归档条目沉底")
expect(sorted.first?.isArchived == false, "displaySorted：未归档在前")
let liveSorted = sorted.filter { !$0.isArchived }
expect(zip(liveSorted, liveSorted.dropFirst()).allSatisfy { $0.expiresAt <= $1.expiresAt }, "displaySorted：未归档按到期升序")
usleep(50_000)   // 保证归档时刻严格早于清理时刻（olderThan: 0 语义）
let countBeforePurge = store.manualItems.count
store.purgeArchived(olderThan: 0)
expect(store.manualItems.first { $0.id == oldSub.id } == nil, "purgeArchived：归档条目被清除")
expect(store.manualItems.first { $0.id == "qreset:" + oldSub.id } == nil, "purgeArchived：连带清除伴生窗口")
expect(store.manualItems.count < countBeforePurge, "purgeArchived：条目数减少")

// ── dataVersion / nextRollInstant ──
let versionBefore = store.dataVersion
var rollProbe = SubItem.manualDefault(name: "滚动探针窗口")
rollProbe.kind = .window
rollProbe.repeatHours = 5
rollProbe.expiresAt = Date().addingTimeInterval(3600)
store.upsertManual(rollProbe)
expect(store.dataVersion > versionBefore, "写入成功后 dataVersion 递增")
// 卡死窗口（不可滚动的过期窗口）不得进入 deadline，否则 roll 分支每秒空转不收敛
var stuckPast = SubItem.manualDefault(name: "卡死过期窗口")
stuckPast.kind = .window
stuckPast.repeatHours = nil
stuckPast.resetRule = nil
stuckPast.expiresAt = Date().addingTimeInterval(-3 * 86400)
store.upsertManual(stuckPast)
expect(store.nextRollInstant() != stuckPast.expiresAt, "nextRollInstant：卡死过期窗口不进 deadline")
expect(store.nextRollInstant()! > Date(), "nextRollInstant：deadline 指向未来")
store.deleteManual(id: stuckPast.id)
expect(store.nextRollInstant() == store.manualItems.filter { $0.kind == .window }.map(\.expiresAt).min(), "nextRollInstant：所有（可滚动）窗口的最小到期时间")
let versionBeforeDelete = store.dataVersion
store.deleteManual(id: rollProbe.id)
expect(store.dataVersion > versionBeforeDelete, "删除成功后 dataVersion 递增")
store.upsertInjection = { _, _ in false }
let versionNoChange = store.dataVersion
_ = store.upsertManual(SubItem.manualDefault(name: "失败探针"))
expect(store.dataVersion == versionNoChange, "写入失败时 dataVersion 不变")
store.upsertInjection = nil

// ── 持久化往返：purchase_at / archived_at 入库后可读回 ──
let reloaded2 = Store()
expect(reloaded2.manualItems.first { $0.name == "Claude 编程月卡" }?.purchaseAt != nil, "purchaseAt 持久化往返")
expect(reloaded2.manualItems.first { $0.name == "神秘服务" }?.updatedAt != nil, "updatedAt 由数据库回填")

// 2026-09-22：实际使用路径的回归。
let checks = Store(environment: ["AR_DATA_DIR": NSTemporaryDirectory() + "ar-review-" + UUID().uuidString])
defer { try? FileManager.default.removeItem(at: checks.dir.deletingLastPathComponent()) }
let fixedNow = date("2026-09-22 12:00")
var stopped = SubItem.manualDefault(name: "已归档窗口")
stopped.kind = .window; stopped.repeatHours = 168
stopped.expiresAt = date("2026-09-11 15:53"); stopped.archivedAt = fixedNow
checks.upsertManual(stopped)
checks.rollManualWindows(now: fixedNow)
expect(checks.manualItems.first!.expiresAt == stopped.expiresAt, "已归档窗口不滚动")
var pending = stopped
pending.id = UUID().uuidString; pending.archivedAt = nil
checks.upsertManual(pending)
checks.upsertInjection = { item, action in action == "roll" ? false : nil }
checks.rollManualWindows(now: fixedNow)
expect(checks.manualItems.first { $0.id == pending.id }!.expiresAt == pending.expiresAt, "滚动写盘失败不提前更新内存")
checks.upsertInjection = nil
checks.rollManualWindows(now: fixedNow)
expect(checks.manualItems.first { $0.id == pending.id }!.expiresAt == date("2026-09-25 15:53"), "失败后可重试，保持原锚点")
let ancient = date("2000-01-01 00:00")
let next = SubItem.nextRollingReset(anchor: ancient, hours: 1, now: fixedNow)
expect(next == date("2026-09-22 13:00"), "超过十万周期的离线窗口一次跳到未来")
expect(SubItem.nextRollingReset(anchor: ancient, hours: .infinity, now: fixedNow) == nil, "无穷周期不参与调度")
expect(checks.saveWindow(name: "异常周期", vendor: nil, expiresAt: fixedNow, repeatHours: .nan) == .parentFailed, "非法周期返回失败而非崩溃")
let before = checks.manualItems.count
expect(checks.saveOneTime(name: "ZCode 一次性会员", vendor: nil, expiresAt: fixedNow).saved, "一次性订阅可保存")
expect(checks.manualItems.count == before + 1, "一次性只新增一条，不凭厂商猜测额度")
var original = SubItem.manualDefault(name: "转换原记录")
original.expiresAt = fixedNow.addingTimeInterval(30 * 86400)
checks.upsertManual(original)
checks.upsertInjection = { item, action in action == "add_week" && item.name.contains("第2/") ? false : nil }
let conversion = checks.saveWeeklySplit(name: original.name, vendor: nil, expiry: original.expiresAt,
                                       firstReset: fixedNow, replacing: original.id, now: fixedNow)
expect(conversion == .parentFailed, "分周写入部分失败，事务整体失败")
expect(checks.manualItems.contains { $0.id == original.id }, "转换失败保留原记录")
expect(!checks.manualItems.contains { $0.name.hasPrefix(original.name + "·第") }, "转换失败不残留半组记录")
checks.upsertInjection = nil
expect(checks.saveWeeklySplit(name: "过长分周", vendor: nil, expiry: fixedNow, firstReset: ancient) == .parentFailed,
       "超长分周拒绝生成大量记录")
