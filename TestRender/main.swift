import AppKit

// 离屏渲染自测：把悬浮窗（展开/收起）、设置后台、编辑表单渲染成 PNG 供人工检查，
// 并对极简表单 / 智能保存管线 / 药丸字号自适应做行为断言。
// 只编译进测试产物（TestRender），不影响正式 .app。

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
    // 先铺一层浅色底，半透明材质更易看清
    if let bgCtx = NSGraphicsContext(bitmapImageRep: rep) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = bgCtx
        NSColor(white: 0.92, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    view.cacheDisplay(in: NSRect(origin: .zero, size: size), to: rep)
    try? rep.representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: path))
    print("rendered: \(path)  \(Int(size.width))x\(Int(size.height))")
    // 硬件合成截图：离屏 cacheDisplay 无法核验原生玻璃。
    if ProcessInfo.processInfo.environment["AR_NATIVE_CAPTURE"] == "1", let window = view.window {
        window.orderFrontRegardless()
        window.displayIfNeeded()
        CATransaction.flush()
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), path.replacingOccurrences(of: ".png", with: "-native.png")]
        try? capture.run()
        capture.waitUntilExit()
        precondition(capture.terminationStatus == 0, "真实窗口截图失败，不得用离屏截图冒充")
    }
}

func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { descendants($0) }
}

final class TestDelegate: NSObject, NSApplicationDelegate {
    var pc: PanelController!

    func applicationDidFinishLaunching(_ n: Notification) {
        Motion.enabled = false   // 截图与断言需要同步最终态
        // 演示手动条目：红(2h) / 绿(36h) / 绿(20天) + 演示官方条目：额度耗尽(白)
        let now = Date()
        var d1 = SubItem.manualDefault(name: "Grok 重置卡", vendor: "xAI")
        d1.expiresAt = now.addingTimeInterval(3600 * 2 + 600)
        d1.kind = .window
        d1.repeatHours = 120
        var d2 = SubItem.manualDefault(name: "中转站 API 月付", vendor: "中转站")
        d2.expiresAt = now.addingTimeInterval(3600 * 36)
        var d3 = SubItem.manualDefault(name: "Netflix 会员", vendor: "其他")
        d3.expiresAt = now.addingTimeInterval(3600 * 24 * 20)
        [d1, d2, d3].forEach { Store.shared.upsertManual($0) }
        Store.shared.upsertManual(SubItem(id: "demo:exhausted",
                                          name: "演示·额度耗尽", vendor: "OpenAI",
                                          kind: .window, expiresAt: now.addingTimeInterval(3600 * 30),
                                          repeatHours: 5, source: "codex", note: "",
                                          usedPercent: 100, groupID: nil))

        pc = PanelController(loadOfficialData: false)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            // 1) 展开态（仅隔离演示条目）
            self.pc.debugSetExpanded(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.pc.debugShowInlineEditor()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    precondition(self.pc.debugContentView!.bounds.width > 100)
                    snapshot(self.pc.debugContentView!, path: "build/render/panel_expanded.png")
                    // 2) 收起态（贴边药丸）。先把最近条目推到「23时59分」（4 数字+3 汉字 > 42pt 可用宽）压测字号自适应
                    var d1long = d1
                    d1long.expiresAt = now.addingTimeInterval(3600 * 23 + 59 * 60)
                    Store.shared.upsertManual(d1long)
                    self.pc.debugSetExpanded(false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        precondition(self.pc.debugPillFontSize < 9, "长倒计时应触发药丸字号自适应缩小")
                        snapshot(self.pc.debugContentView!, path: "build/render/panel_pill.png")
                        // 3) 设置后台
                        let sc = SettingsWindowController(panel: self.pc)
                        sc.showWindow(nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            sc.debugPrintGeometry()
                            snapshot(sc.windowRef!.contentView!, path: "build/render/settings.png")
                            self.behaviorTests(now: now)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                NSApp.terminate(nil)
                            }
                        }
                    }
                }
            }
        }
    }

    /// 行为断言：智能保存管线（自动命名/伴生窗口/编辑平移/归档）+ 极简表单失败保留输入
    private func behaviorTests(now: Date) {
        // ── 智能管线：名称可识别、供应商留空 → 反向识别厂商 + 自动伴生重置窗口 ──
        precondition(Store.shared.saveInferred(name: "Codex 额度", vendor: nil,
                                               expiresAt: now.addingTimeInterval(5 * 3600),
                                               purchaseAt: nil).saved)
        let codexParent = Store.shared.manualItems
            .first { $0.kind == .subscription && $0.name == "Codex 额度" }
        precondition(codexParent != nil, "非空名称应原样保留")
        precondition(codexParent?.vendor == "OpenAI", "名称含 Codex 应回收为 OpenAI")
        let codexComp = Store.shared.manualItems
            .first { $0.id == SubItem.quotaResetId(for: codexParent!.id) }
        precondition(codexComp != nil && codexComp!.kind == .window,
                     "已知名额厂商应自动生成重置伴生窗口")

        // ── 未知厂商：不凭空造重置窗口 ──
        precondition(Store.shared.saveInferred(name: "神秘年费", vendor: nil,
                                               expiresAt: now.addingTimeInterval(365 * 86400),
                                               purchaseAt: nil).saved)
        let mystery = Store.shared.manualItems.first { $0.name.contains("神秘年费") }!
        precondition(Store.shared.manualItems.first { $0.id == SubItem.quotaResetId(for: mystery.id) } == nil,
                     "未知厂商不得凭空生成重置窗口")

        // ── 编辑平移：改父条目到期 → 滚动伴生锚点同差值平移 ──
        var edited = codexParent!
        let oldExpiry = edited.expiresAt
        edited.expiresAt = oldExpiry.addingTimeInterval(3600)
        precondition(Store.shared.updateManual(edited, previousExpiry: oldExpiry).saved)
        let movedComp = Store.shared.manualItems
            .first { $0.id == SubItem.quotaResetId(for: edited.id) }!
        precondition(abs(movedComp.expiresAt.timeIntervalSince(codexComp!.expiresAt.addingTimeInterval(3600))) < 1,
                     "编辑到期应平移滚动伴生锚点")
        print("PASS: 智能管线自动命名/伴生窗口/未知厂商不造窗口/编辑平移")

        // ── 极简表单：保存失败保持打开、输入保留；成功正常关闭并走推断管线 ──
        EditorSheetController.showsSaveFailureAlerts = false
        let failParent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 20, height: 20),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        var draft = SubItem.manualDefault(name: "", vendor: "")
        draft.expiresAt = now.addingTimeInterval(7 * 86400)
        let failEditor = EditorSheetController(item: draft, isNew: true)
        failParent.beginSheet(failEditor.window!)
        let failName = descendants(failEditor.window!.contentView!)
            .compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == "可选，留空自动命名" }!
        failName.stringValue = "失败探针"
        failEditor.onSave = { _, _, _ in false }
        failEditor.perform(NSSelectorFromString("saveClicked"))
        precondition(failEditor.window!.sheetParent != nil, "保存失败时表单必须保持打开")
        precondition(failName.stringValue == "失败探针", "保存失败时输入必须原样保留")
        precondition(EditorSheetController.lastSaveFailureMessage == "保存失败", "失败文案应可断言")
        snapshot(failEditor.window!.contentView!, path: "build/render/editor.png")
        failEditor.onSave = { item, previousExpiry, weeklyAnchor in
            precondition(previousExpiry == nil, "新建路径 previousExpiry 应为 nil")
            precondition(weeklyAnchor == nil, "周期窗口路径不应携带周拆分锚点")
            if item.kind == .window {
                return Store.shared.saveWindow(name: item.name, vendor: item.vendor,
                                               expiresAt: item.expiresAt,
                                               repeatHours: item.repeatHours ?? 168).saved
            }
            return Store.shared.saveInferred(name: item.name, vendor: item.vendor,
                                             expiresAt: item.expiresAt, purchaseAt: nil).saved
        }
        // 选「周期额度 · 每周」（档位 2）→ 保存为 168h 滚动窗口（周额度界定 + 倒推窗口起点）
        let typePopup = descendants(failEditor.window!.contentView!).compactMap { $0 as? NSPopUpButton }.first!
        typePopup.selectItem(at: 2)
        failEditor.perform(NSSelectorFromString("saveClicked"))
        precondition(failEditor.window!.sheetParent == nil, "成功后表单正常关闭")
        let weeklyFormEntry = Store.shared.manualItems.first { $0.name == "失败探针" && $0.kind == .window }
        precondition(weeklyFormEntry?.repeatHours == 168 && weeklyFormEntry?.resetRule == .rolling,
                     "表单选周期额度·每周 → 保存为 168h 滚动窗口")
        precondition(weeklyFormEntry?.purchaseAt == weeklyFormEntry?.expiresAt.addingTimeInterval(-168 * 3600),
                     "周期窗口保存时窗口起点倒推为 到期−周期")
        EditorSheetController.showsSaveFailureAlerts = true
        print("PASS: 极简表单失败保留输入、成功走推断管线关闭")
        print("PASS: 类型档位选周额度 → 168h 滚动窗口 + 起点倒推")

        // ── 「订阅 · 周额度重置」：官方节奏拆第k/n周组（显式输入首次重置 now+7 天）──
        var grokDraft = SubItem.manualDefault(name: "Grok 月卡", vendor: "xAI")
        grokDraft.expiresAt = now.addingTimeInterval(27 * 86400)
        let splitEditor = EditorSheetController(item: grokDraft, isNew: true)
        failParent.beginSheet(splitEditor.window!)
        let splitPopup = descendants(splitEditor.window!.contentView!).compactMap { $0 as? NSPopUpButton }.first!
        splitPopup.selectItem(at: 1)   // 订阅 · 周额度重置（第k/n周）
        // 两个日期初值相同；按控件遍历顺序取第二个（首次重置）。
        let datePickers = descendants(splitEditor.window!.contentView!).compactMap { $0 as? NSDatePicker }
        precondition(datePickers.count == 2)
        datePickers[1].dateValue = now.addingTimeInterval(7 * 86400)
        splitEditor.onSave = { item, _, anchor in
            precondition(anchor != nil, "周额度重置路径必须携带首次重置锚点")
            precondition(item.kind == .subscription, "周额度重置主体是订阅而非窗口")
            return Store.shared.saveWeeklySplit(name: item.name, vendor: item.vendor,
                                                expiry: item.expiresAt, firstReset: anchor!).saved
        }
        splitEditor.perform(NSSelectorFromString("saveClicked"))
        precondition(splitEditor.window!.sheetParent == nil, "拆分保存后表单正常关闭")
        let splitMembers = Store.shared.manualItems
            .filter { $0.name.hasPrefix("Grok 月卡·第") }
            .sorted { $0.expiresAt < $1.expiresAt }
        precondition(splitMembers.count == 3, "27 天订阅自 now+7 锚点应拆 3 轮（3×7=21≤27<28）")
        precondition(splitMembers.first?.name == "Grok 月卡·第1/3周" && splitMembers.last?.name == "Grok 月卡·第3/3周",
                     "第k/n周命名")
        precondition(Set(splitMembers.compactMap(\.groupID)).count == 1, "拆分组成员共享 groupID")
        precondition(splitMembers.last!.expiresAt < grokDraft.expiresAt, "末轮叠不满订阅到期")
        print("PASS: 订阅周额度重置 → 第k/n周组（显式输入首次重置 now+7，末轮叠不满到期）")

        var month31 = SubItem.manualDefault(name: "31天周期")
        month31.kind = .window; month31.repeatHours = 744
        let keepEditor = EditorSheetController(item: month31, isNew: false)
        var kept: SubItem?
        keepEditor.onSave = { item, _, _ in kept = item; return true }
        keepEditor.perform(NSSelectorFromString("saveClicked"))
        precondition(kept?.repeatHours == 744, "重新保存不能把31天周期改成30天")
        pc.perform(NSSelectorFromString("hideClicked"))
        for _ in 0..<31 { pc.tick() }
        precondition(pc.debugContentView?.window?.isVisible == false, "用户隐藏不应被心跳重新拉起")
        pc.showPanel()
        precondition(pc.debugContentView?.layer?.filters?.isEmpty != false, "玻璃根容器不得挂模糊滤镜")
        print("PASS: 31天周期保持、主动隐藏、玻璃根容器无滤镜")

        // ── tooltip 语义：额度重置窗口称「重置/下次重置」，手动通用周期窗口仍称「到期」 ──
        let qresetProbe = SubItem(id: "qreset:探针", name: "探针·周重置", vendor: "探针",
                                  kind: .window, expiresAt: now.addingTimeInterval(3600),
                                  repeatHours: 168, source: "manual", note: "",
                                  usedPercent: nil, groupID: nil)
        var manualWindow = SubItem.manualDefault(name: "月付续费日")
        manualWindow.kind = .window
        manualWindow.repeatHours = 720
        precondition(RowView.detailTooltip(qresetProbe, now: now).contains("下次重置"), "周重置伴生窗口 tooltip 应称下次重置")
        precondition(!RowView.detailTooltip(manualWindow, now: now).contains("下次重置"), "手动通用窗口 tooltip 不得称下次重置")
        precondition(!RowView.detailTooltip(qresetProbe, now: now).contains("提醒"), "提醒功能已删除，tooltip 不得再出现提醒字样")
        print("PASS: tooltip 按额度重置语义精确区分")
    }
}

// 渲染测试会写入演示记录；裸跑二进制时必须在接触 Store 前拒绝正式数据目录。
let testEnvironment = ProcessInfo.processInfo.environment
guard let isolatedRoot = testEnvironment["AR_DATA_DIR"], !isolatedRoot.isEmpty else {
    fputs("TestRender 必须通过 test_render.sh 在隔离数据目录运行\n", stderr)
    exit(2)
}
let testRoot = URL(fileURLWithPath: isolatedRoot, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
let liveRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .resolvingSymlinksInPath().standardizedFileURL
guard testRoot != liveRoot else {
    fputs("TestRender 不得使用正式数据目录\n", stderr)
    exit(2)
}

let app = NSApplication.shared
let d = TestDelegate()
app.delegate = d
app.setActivationPolicy(.accessory)
ProcessInfo.processInfo.disableAutomaticTermination("render test")   // 绕开 LS 同步上报（裸进程会卡）
app.disableRelaunchOnLogin()
app.run()
