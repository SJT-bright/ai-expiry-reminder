import AppKit

// 人工填表模拟测试台：经真实表单路径（openEditor → 真实控件 → 点击「保存」）
// 添加 14 个基于真实供应商规则的场景，逐个核对生成结果是否符手工推演的预期。
// 只编译进测试产物（TestManual），不影响正式 .app。数据写入隔离的临时目录。

func descendants(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap { descendants($0) } }

func snapshot(_ view: NSView, path: String) {
    view.layoutSubtreeIfNeeded()
    view.layoutSubtreeIfNeeded()
    let size = view.bounds.size
    let scale: CGFloat = 2
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(size.width * scale),
                                     pixelsHigh: Int(size.height * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .calibratedRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = size
    if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor(white: 0.92, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    view.cacheDisplay(in: NSRect(origin: .zero, size: size), to: rep)
    try? rep.representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: path))
}

/// 一个填表场景：(名称, 供应商, 类型档位下标, 到期偏移秒, 首次重置偏移秒或 nil, 结果核对)
typealias Scenario = (label: String, name: String, vendor: String, type: Int,
                      expiry: TimeInterval, firstReset: TimeInterval?, verify: () -> Void)

var failures: [String] = []
func check(_ cond: Bool, _ msg: String) {
    print("[\(cond ? "PASS" : "FAIL")] \(msg)")
    if !cond { failures.append(msg) }
}
func note(_ msg: String) { print("[FINDING] \(msg)") }
/// 表单只能表达到分钟（DateTextField 无秒位），故输入与预期一律对齐到整分钟后再比；
/// 容差只留 5 秒余量，日/小时级偏差照样能抓到。
func approx(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) < 5 }
func members(_ prefix: String) -> [SubItem] {
    Store.shared.manualItems.filter { $0.name.hasPrefix(prefix) }.sorted { $0.expiresAt < $1.expiresAt }
}
/// 伴生周期重置窗口：id = "qreset:" + 父条目 id，命名 <父条目>·周期重置（Models.ResetWindowFactory）。
/// 按父条目精确关联，不用名称前缀（"SuperGrok" 会误吞 "SuperGrok Heavy"）。
func phantomWindows(of parentName: String) -> [SubItem] {
    let items = Store.shared.manualItems
    let linked = Set(items.filter { $0.name == parentName }.map { SubItem.quotaResetId(for: $0.id) })
    return items.filter { linked.contains($0.id) || $0.name == "\(parentName)·周期重置" }
}
/// 周组结构核对：首档=锚点、相邻严格 7 天、末档≤到期、末档+7 天>到期（缺轮即破）。
/// 用边界性质替代「重算轮数」，避免测试用生产同一套公式自证。
func checkWeeklyStructure(_ m: [SubItem], _ label: String, anchor: Date, expiry: Date, day: TimeInterval) {
    guard m.count >= 2 else {
        check(false, "\(label)：周期组条目数应 ≥ 2 才能逐轮核对，实际 \(m.count)")
        return
    }
    check(approx(m.first!.expiresAt, anchor), "\(label)：首档 = 首次重置锚点")
    let gaps = zip(m, m.dropFirst()).map { $1.expiresAt.timeIntervalSince($0.expiresAt) }
    let gapDays = gaps.map { Int(($0 / day).rounded()) }
    check(gaps.allSatisfy { abs($0 - 7 * day) < 5 },
          "\(label)：相邻档位严格 7 天（实测 \(gapDays) 天）")
    check(m.last!.expiresAt <= expiry.addingTimeInterval(1), "\(label)：末档不越过订阅到期")
    check(m.last!.expiresAt.addingTimeInterval(7 * day) > expiry,
          "\(label)：末档 +7 天已越过到期（无漏拆轮次）")
}

final class Delegate: NSObject, NSApplicationDelegate {
    /// 14 个场景落库使用的基名，供全局杂散条目兜底
    static let scenarioNames = ["Codex Plus", "Grok 月卡", "Claude Pro", "GLM Coding Plan", "SuperGrok",
                                "Qwen Code 月付", "Cursor Pro", "GitHub Copilot", "中转站 API 包月",
                                "边界探针A", "边界探针B", "Netflix 会员", "未分类·订阅", "SuperGrok Heavy"]

    var pc: PanelController!
    let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 30, height: 30),
                          styleMask: [.titled], backing: .buffered, defer: false)
    /// 对齐到整分钟：表单无秒位，写入必然被截到分钟；预期同样以整分钟起算，
    /// 否则误差上界逼近容差，且 ceil() 类建议文案会随时钟秒数翻档（同一天跑两次结论不同）。
    let now: Date = {
        let t = Date().timeIntervalSince1970
        return Date(timeIntervalSince1970: (t / 60).rounded(.down) * 60)
    }()
    let DAY = 86400.0
    let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd HH:mm"
        f.timeZone = .current
        return f
    }()

    func applicationDidFinishLaunching(_ n: Notification) {
        Motion.enabled = false
        // 写入失败必须走断言而不是系统弹窗：runModal 会卡在 performClick 里，
        // 整条 asyncAfter 链路永不返回，测试表现为「挂住」而非报出失败。
        EditorSheetController.showsSaveFailureAlerts = false
        // 看门狗：任何未预料的阻塞都该表现为明确失败，而不是让测试静默挂死
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            fputs("TIMEOUT：14 个场景未在 90 秒内跑完\n", stderr)
            exit(3)
        }
        parent.orderFrontRegardless()
        pc = PanelController(loadOfficialData: false)

        // (label, name, vendor, typeIndex, expiry 秒, firstReset 秒或 nil, verify)
        var scenarios: [Scenario] = []

        // ── 基于真实供应商规则的场景（调研结论见 README/RESEARCH.md）──
        // S1 Codex Plus：2026-07 起 5h 窗口暂停，周限额按账期重置 → 订阅·周额度重置
        scenarios.append(("S1 Codex周额度(短首轮+末轮白嫖)", "Codex Plus", "OpenAI", 1, 31 * DAY, 2 * DAY, {
            let m = members("Codex Plus·第")
            check(m.count == 5, "S1：+31d 到期、+2d 首重 → 应拆 5 轮，实际 \(m.count)")
            check(m.first?.name == "Codex Plus·第1/5周" && approx(m.first!.expiresAt, self.now.addingTimeInterval(2 * self.DAY)),
                  "S1：首周 +2d 命名 第1/5周")
            check(m.last?.name == "Codex Plus·第5/5周" && approx(m.last!.expiresAt, self.now.addingTimeInterval(30 * self.DAY)),
                  "S1：末周 +30d（叠不满 +31d 到期）")
            checkWeeklyStructure(m, "S1", anchor: self.now.addingTimeInterval(2 * self.DAY),
                                      expiry: self.now.addingTimeInterval(31 * self.DAY), day: self.DAY)
            // 建议文案是「整组一条」写入的（Models.saveWeeklySplit 对每轮复用同一串），
            // 故只能核对组级内容，无法逐轮区分首轮/末轮措辞。
            check(m.allSatisfy { $0.note.contains("快点用") && $0.note.contains("2 天") },
                  "S1：组内建议含首轮 2 天快点用")
            check(m.allSatisfy { $0.note.contains("再等 6 天") },
                  "S1：组内建议含续买再等 6 天（30+7−31）")
        }))
        // S2 Grok 重置卡：用户原始场景（3 天首轮，27 天订阅 → 4 轮，白嫖 3 天，再等 4 天）
        scenarios.append(("S2 Grok重置卡(用户场景)", "Grok 月卡", "xAI", 1, 27 * DAY, 3 * DAY, {
            let m = members("Grok 月卡·第")
            check(m.count == 4, "S2：+27d 到期、+3d 首重 → 4 轮，实际 \(m.count)")
            check(m.last?.name == "Grok 月卡·第4/4周" && approx(m.last!.expiresAt, self.now.addingTimeInterval(24 * self.DAY)),
                  "S2：末周 +24d（叠不满 +27d）")
            checkWeeklyStructure(m, "S2", anchor: self.now.addingTimeInterval(3 * self.DAY),
                                      expiry: self.now.addingTimeInterval(27 * self.DAY), day: self.DAY)
            check(m.first?.note.contains("3 天白嫖") == true && m.first?.note.contains("再等 4 天") == true,
                  "S2：建议含 3 天白嫖 → 续买再等 4 天")
        }))
        // S3 Claude Pro：5h 滚动会话窗口 → 周期额度·5小时
        scenarios.append(("S3 Claude 5h窗口", "Claude Pro", "Anthropic", 4, 5 * 3600, nil, {
            let m = Store.shared.manualItems.first { $0.name == "Claude Pro" }
            check(m?.kind == .window && m?.repeatHours == 5, "S3：Claude 5h → 滚动窗口 repeatHours=5")
            check(m?.purchaseAt != nil && approx(m!.purchaseAt!, self.now.addingTimeInterval(0)),
                  "S3：窗口起点倒推 = 到期 − 5h ≈ 现在")
        }))
        // S4 智谱 GLM Coding Plan：5h 积分滚动 → 周期额度·5小时
        scenarios.append(("S4 GLM 5h窗口", "GLM Coding Plan", "智谱", 4, 5 * 3600, nil, {
            let m = Store.shared.manualItems.first { $0.name == "GLM Coding Plan" }
            check(m?.kind == .window && m?.repeatHours == 5, "S4：GLM 5h → 滚动窗口")
        }))
        // S5 SuperGrok 月付（纯订阅无周期）→ 一次性
        scenarios.append(("S5 SuperGrok月付", "SuperGrok", "xAI", 0, 30 * DAY, nil, {
            let m = Store.shared.manualItems.first { $0.name == "SuperGrok" }
            check(m?.kind == .subscription && m?.repeatHours == nil, "S5：SuperGrok 月付 → 纯订阅")
            // 「凭空生成周期窗口」的形态是伴生窗口（名称 <父>·周期重置 / id 前缀 qreset:），
            // 不是「·第k/n周」；查 SuperGrok·第 前缀永远为空，等于没断言。
            check(phantomWindows(of: "SuperGrok").isEmpty, "S5：不凭空生成周期窗口（无 ·周期重置 / qreset: 伴生）")
        }))
        // S6 通义千问：每周一 00:00 重置 → 锚点取下一个周一，7 天步进应保持周一
        let cal = Calendar.current
        let nextMonday = cal.startOfDay(for: {
            var d = self.now
            while cal.component(.weekday, from: d) != 2 { d = d.addingTimeInterval(self.DAY) }
            return d
        }())
        let qwenExpiry = self.now.addingTimeInterval(45 * self.DAY)
        scenarios.append(("S6 千问每周一", "Qwen Code 月付", "阿里云", 1, 45 * DAY, nextMonday.timeIntervalSince(self.now), {
            let m = members("Qwen Code 月付·第")
            // 轮数不再用生产同款 floor(span/7)+1 复算（自证断言：公式写错也照样过）；
            // 改由边界性质唯一确定轮数——首档=锚点、严格 7 天步进、末档≤到期且末档+7天>到期。
            checkWeeklyStructure(m, "S6", anchor: nextMonday, expiry: qwenExpiry, day: self.DAY)
            check(m.count >= 2 && m.allSatisfy { cal.component(.weekday, from: $0.expiresAt) == 2 },
                  "S6：所有轮次都落在周一（7 天步进保持星期）")
            check(m.count >= 2 && m.allSatisfy { cal.component(.hour, from: $0.expiresAt) == 0 },
                  "S6：全部 00:00 锚定")
            check(m.count >= 2 && m.enumerated().allSatisfy { i, it in
                it.name == "Qwen Code 月付·第\(i + 1)/\(m.count)周"
            }, "S6：命名 第k/n周 与实际轮数自洽（n=\(m.count)）")
        }))
        // S7 Cursor Pro 月付 → 一次性
        scenarios.append(("S7 Cursor月付", "Cursor Pro", "Cursor", 0, 30 * DAY, nil, {
            let m = Store.shared.manualItems.first { $0.name == "Cursor Pro" }
            check(m?.kind == .subscription && m?.vendor == "Cursor", "S7：Cursor → 一次性订阅，供应商保留")
        }))
        // S8 GitHub Copilot（供应商留空，名称不可识别）→ 未分类
        scenarios.append(("S8 Copilot留空供应商", "GitHub Copilot", "", 0, 25 * DAY, nil, {
            let m = Store.shared.manualItems.first { $0.name == "GitHub Copilot" }
            check(m?.vendor == "未分类", "S8：名称无厂商关键词 → 未分类")
        }))
        // S9 中转站 30 天卡 → 周期额度·每月（30 天）
        scenarios.append(("S9 中转站30天", "中转站 API 包月", "中转站", 3, 30 * DAY, nil, {
            let m = Store.shared.manualItems.first { $0.name == "中转站 API 包月" }
            check(m?.kind == .window && m?.repeatHours == 720, "S9：中转站 30 天 → 720h 滚动窗口")
        }))
        // S10 边界：首次重置 = 订阅到期 → 仅 1 轮且当轮作废
        scenarios.append(("S10 首重即到期", "边界探针A", "其他", 1, 7 * DAY, 7 * DAY, {
            let m = members("边界探针A·第")
            check(m.count == 1 && m.first?.name == "边界探针A·第1/1周", "S10：锚点=到期 → 仅 1 轮 第1/1周")
            check(m.first?.note.contains("重置即到期") == true, "S10：note 提示该轮额度来不及用")
        }))
        // S11 边界：首轮明天（1 天短首轮）
        scenarios.append(("S11 首轮1天", "边界探针B", "xAI", 1, 15 * DAY, 1 * DAY, {
            let m = members("边界探针B·第")
            check(m.count == 3, "S11：+15d 到期、+1d 首重 → 3 轮，实际 \(m.count)")
            checkWeeklyStructure(m, "S11", anchor: self.now.addingTimeInterval(1 * self.DAY),
                                      expiry: self.now.addingTimeInterval(15 * self.DAY), day: self.DAY)
            check(m.last?.name == "边界探针B·第3/3周" && approx(m.last!.expiresAt, self.now.addingTimeInterval(15 * self.DAY)),
                  "S11：末档恰好落在到期日（1+7+7=15）")
            check(m.first?.note.contains("1 天") == true && m.first?.note.contains("快点用") == true,
                  "S11：首轮 1 天 → 快点用")
        }))
        // S12 Netflix 年付 → 一次性长周期
        scenarios.append(("S12 Netflix年付", "Netflix 会员", "其他", 0, 300 * DAY, nil, {
            let m = Store.shared.manualItems.first { $0.name == "Netflix 会员" }
            check(m?.kind == .subscription, "S12：年付 → 一次性订阅")
        }))
        // S13 全空输入：名称/供应商都留空 → 自动命名「供应商·订阅」
        scenarios.append(("S13 全空自动命名", "", "", 0, 10 * DAY, nil, {
            let m = Store.shared.manualItems.first { $0.name == "未分类·订阅" }
            check(m != nil && m?.vendor == "未分类", "S13：全空 → 自动命名 未分类·订阅")
        }))
        // S14 SuperGrok Heavy：2 小时滚动窗口（调研确认的官方节奏）→ 周期额度·2小时
        scenarios.append(("S14 Grok 2h窗口", "SuperGrok Heavy", "xAI", 5, 2 * 3600, nil, {
            let m = Store.shared.manualItems.first { $0.name == "SuperGrok Heavy" }
            check(m?.kind == .window && m?.repeatHours == 2, "S14：Grok 2h → 滚动窗口 repeatHours=2")
        }))

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            self.pc.debugSetExpanded(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let probe = SubItem.manualDefault(name: "", vendor: "")
                self.pc.openEditor(probe, isNew: true, on: self.parent, saved: {}, deleted: {})
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let popup = descendants(self.parent.attachedSheet!.contentView!)
                        .compactMap { $0 as? NSPopUpButton }.first!
                    let titles = popup.itemTitles
                    note("类型档位：\(titles.joined(separator: " / "))")
                    let cancel = descendants(self.parent.attachedSheet!.contentView!)
                        .compactMap { $0 as? NSButton }.first { $0.title == "取消" }
                    cancel?.performClick(nil)
                    // 等探针表单真正detach 再开第一张：否则 openEditor 会撞在收尾中的 sheet 上
                    self.waitSheetClosed { self.runScenarioLoop(scenarios, titles: titles) }
                }
            }
        }
    }

    /// 强制关掉残留表单（等它真正 detach）后继续，避免污染后续场景
    func closeSheetThen(_ body: @escaping () -> Void) {
        guard let sheet = parent.attachedSheet else { body(); return }
        if let cancel = descendants(sheet.contentView!).compactMap({ $0 as? NSButton })
            .first(where: { $0.title == "取消" }) {
            cancel.performClick(nil)
        } else if let host = sheet.sheetParent {
            host.endSheet(sheet)
        }
        waitSheetClosed(body)
    }

    func runScenarioLoop(_ scenarios: [Scenario], titles: [String]) {
        var i = 0
        func runNext() {
            guard i < scenarios.count else { finish(titles: titles); return }
            let s = scenarios[i]
            i += 1
            // 由场景自己收尾再跑下一个：原先固定 0.18s 猜时序，验证会与下一张表单互相踩
            simulate(s, done: runNext)
        }
        runNext()
    }

    /// endSheet 的收尾是异步的：轮询等表单 detach（上限 ~0.6s），超时交由调用方判定
    func waitSheetClosed(_ body: @escaping () -> Void, attempt: Int = 0) {
        if parent.attachedSheet == nil || attempt >= 10 { body(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            self.waitSheetClosed(body, attempt: attempt + 1)
        }
    }

    func simulate(_ s: Scenario, done: @escaping () -> Void) {
        var draft = SubItem.manualDefault(name: "", vendor: "")
        draft.expiresAt = now.addingTimeInterval(s.expiry)
        pc.openEditor(draft, isNew: true, on: parent, saved: {}, deleted: {})
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let sheet = self.parent.attachedSheet else {
                check(false, "\(s.label)：表单未挂载")
                done()
                return
            }
            let views = descendants(sheet.contentView!)
            let nameField = views.compactMap { $0 as? NSTextField }
                .first { $0.placeholderString == "可选，留空自动命名" }
            let combo = views.compactMap { $0 as? NSComboBox }.first
            let popup = views.compactMap { $0 as? NSPopUpButton }.first
            let expiryField = views.compactMap { $0 as? DateTextField }
                .first { $0.accessibilityIdentifier() == "expiryField" }
            let firstResetField = views.compactMap { $0 as? DateTextField }
                .first { $0.accessibilityIdentifier() == "firstResetField" }
            guard let nameField, let combo, let popup, let expiryField else {
                check(false, "\(s.label)：表单控件不齐")
                self.closeSheetThen(done)
                return
            }
            if s.firstReset != nil, firstResetField == nil {
                check(false, "\(s.label)：场景要写首次重置，但表单里找不到 firstResetField"
                      + "（静默跳过会拿默认锚点跑，结论失真）")
                self.closeSheetThen(done)
                return
            }
            nameField.stringValue = s.name
            combo.stringValue = s.vendor
            popup.selectItem(at: s.type)
            expiryField.setText(self.df.string(from: self.now.addingTimeInterval(s.expiry)))
            if let fr = s.firstReset {
                firstResetField!.setText(self.df.string(from: self.now.addingTimeInterval(fr)))
            }
            // 点击真实的「保存」按钮
            let save = views.compactMap { $0 as? NSButton }.first { $0.title == "保存" }
            guard let save else {
                check(false, "\(s.label)：找不到保存按钮")
                self.closeSheetThen(done)
                return
            }
            EditorSheetController.lastSaveFailureMessage = nil
            save.performClick(nil)
            self.waitSheetClosed {
                if self.parent.attachedSheet != nil {
                    // 保存被拒（如锚点晚于到期）时表单保持挂载、也不弹窗：
                    // 不点出来的话，verify 就是在对着上一轮的数据断言。
                    let texts = descendants(self.parent.attachedSheet!.contentView!)
                        .compactMap { $0 as? NSTextField }.map { $0.stringValue }.filter { !$0.isEmpty }
                    // 按关键词优先级取错误提示，避免抓到同屏的预览文案
                    var hint: String?
                    for keyword in ["失败", "需早于", "该条目", "最多拆分"] where hint == nil {
                        hint = texts.first { $0.contains(keyword) }
                    }
                    check(false, "\(s.label)：保存未提交，表单仍打开"
                          + (hint.map { "（表单提示：\($0)）" } ?? ""))
                    self.closeSheetThen(done)
                    return
                }
                let writeErr = EditorSheetController.lastSaveFailureMessage
                check(writeErr == nil,
                      "\(s.label)：无写入失败" + (writeErr.map { "（实际：\($0)）" } ?? ""))
                s.verify()
                done()
            }
        }
    }

    func finish(titles: [String]) {
        pc.debugSetExpanded(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            snapshot(self.pc.debugContentView!, path: "build/render/manual_panel_expanded.png")
            self.pc.debugSetExpanded(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                snapshot(self.pc.debugContentView!, path: "build/render/manual_panel_pill.png")
                // 全局兜底：14 个场景之外不得有杂散写入（伴生窗口、重复入库等）
                let strays = Store.shared.manualItems.filter { it in
                    !Self.scenarioNames.contains { $0 == it.name || it.name.hasPrefix("\($0)·") }
                }
                check(strays.isEmpty, "全局：场景之外不得有杂散条目（实际 \(strays.map { $0.name })）")
                print("—— 汇总 ——")
                print("条目总数：\(Store.shared.manualItems.count)（含周组展开）")
                if failures.isEmpty {
                    print("ALL PASS：\(titles.count) 档位下 14 个场景全部符合手工预期")
                    exit(0)
                }
                print("FAILURES(\(failures.count))：")
                failures.forEach { print("  ✗ \($0)") }
                fflush(stdout)
                exit(1)   // 失败必须反映到退出码：原先 terminate 一律 0，脚本报不出红
            }
        }
    }
}

let testEnvironment = ProcessInfo.processInfo.environment
guard let isolatedRoot = testEnvironment["AR_DATA_DIR"], !isolatedRoot.isEmpty else {
    fputs("TestManual 会真实写库，必须通过 test_manual.sh 在隔离数据目录运行\n", stderr)
    exit(2)
}
let testRoot = URL(fileURLWithPath: isolatedRoot, isDirectory: true)
    .resolvingSymlinksInPath().standardizedFileURL
let liveRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .resolvingSymlinksInPath().standardizedFileURL
guard testRoot != liveRoot else {
    fputs("TestManual 不得使用正式数据目录\n", stderr)
    exit(2)
}

let app = NSApplication.shared
let d = Delegate()
app.delegate = d
app.setActivationPolicy(.accessory)
ProcessInfo.processInfo.disableAutomaticTermination("manual test")
app.disableRelaunchOnLogin()
app.run()
