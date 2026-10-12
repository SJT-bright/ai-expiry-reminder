import AppKit

// 离屏渲染自测：把悬浮窗（展开/收起）、设置后台、编辑表单渲染成 PNG 供人工检查，
// 并对极简表单 / 智能保存管线 / 胶囊稳定文字布局做行为断言。
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
        Store.shared.state.panelAutoCollapse = true  // 既有自动收起场景继续验证；手动模式另测。
        // 音效和悬停上浮都认这个开关，测试保持静音、无动画
        // ⑦ 首用引导：必须在播种前以空库走一次真实 showPanel——
        //    新用户第一眼应该看到自动展开的「暂无条目，点 ＋ 添加」，而不是裸 ⏳ 药丸
        pc = PanelController(loadOfficialData: false)
        pc.showPanel()
        topmostTests()
        let glassHost = pc.debugContentView?.window?.contentView as? GlassSurface
        precondition(glassHost?.contentView === pc.debugContentView,
                     "文字和交互必须由玻璃 contentView 承载，不能放在不保证层级的兄弟视图")
        precondition(Store.shared.state.autoExpandDone == true,
                     "⑦ 首次 showPanel 应写入引导标记，实际 \(String(describing: Store.shared.state.autoExpandDone))")
        precondition(pc.debugContentView?.window?.frame.width == 240,
                     "⑦ 空库首启应自动展开面板露出引导文案，实际宽 \(pc.debugContentView?.window?.frame.width ?? 0)")
        pc.applyCollapsed(true)   // 回到收起态，后续截图流程从药丸开始
        precondition(pc.debugPillLabel.stringValue == "暂无记录", "空胶囊必须说明当前状态")
        precondition(pc.debugPillLabel.alphaValue == 1, "空状态不得继承倒计时的透明度")
        if let win = pc.debugContentView?.window {   // 光标固定在面板内取消计时器：测试期间不得被 8s 收起打断
            PanelController.debugCursorOverride = NSPoint(x: win.frame.midX, y: win.frame.midY)
            pc.debugHeartbeatResync()
            PanelController.debugCursorOverride = nil
        }

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

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            self.windowStackTest()
            // 1) 展开态（仅隔离演示条目）
            self.pc.debugSetExpanded(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.pc.debugShowInlineEditor()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    precondition(self.pc.debugContentView!.bounds.width > 100)
                    snapshot(self.pc.debugContentView!, path: "build/render/panel_expanded.png")
                    // 2) 收起态：最长的时分组合必须在原尺寸内完整显示。
                    var d1long = d1
                    d1long.expiresAt = now.addingTimeInterval(3600 * 23 + 59 * 60)
                    Store.shared.upsertManual(d1long)
                    self.pc.debugSetExpanded(false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        precondition(self.pc.debugContentView!.bounds.size == NSSize(width: 54, height: 18), "胶囊必须保持用户指定的原尺寸54×18")
                        precondition(self.pc.debugPillFontSize >= 6.5 && self.pc.debugPillFontSize <= 9, "长倒计时应在原字号范围适配")
                        let label = self.pc.debugPillLabel
                        let fullTextWidth = (label.stringValue as NSString).size(withAttributes: [.font: label.font!]).width
                        precondition(ceil(fullTextWidth) + 4 <= label.frame.width, "完整原文与cell内边距必须放入胶囊，不能用已截断的intrinsic宽度冒充")
                        precondition(self.pc.debugContentView!.bounds.contains(label.frame), "文字框不得越界")
                        let fixedFrame = label.frame
                        for _ in 0..<12 {
                            self.pc.debugSetExpanded(true)
                            self.pc.debugSetExpanded(false)
                        }
                        precondition(label.frame == fixedFrame && label.alphaValue == 1,
                                     "重复展开/收起不得裁剪或淡出倒计时")
                        print("PASS: 胶囊长倒计时可读、重复切换文字框稳定")
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
    private func topmostTests() {
        let window = pc.debugContentView!.window!
        // 启动后模拟系统撤下窗口，心跳应恢复；主动隐藏仍有自己的出口。
        window.orderOut(nil)
        pc.tick()
        precondition(window.isVisible, "非用户隐藏必须在一次心跳内恢复")
        let keyBefore = NSApp.keyWindow
        pc.restoreToTopRight()
        let screen = window.screen!
        precondition(window.frame.size == NSSize(width: 54, height: 18)
                     && abs(window.frame.maxX - (screen.visibleFrame.maxX - 6)) < 1
                     && abs(window.frame.maxY - (screen.visibleFrame.maxY - 8)) < 1,
                     "恢复入口应在当前操作屏右上角显示原尺寸胶囊")
        precondition(NSApp.keyWindow === keyBefore, "置顶恢复不得抢键盘焦点")
        precondition(window.collectionBehavior.contains([.canJoinAllApplications, .canJoinAllSpaces,
                                                        .fullScreenAuxiliary, .stationary]) && !window.canHide,
                     "覆盖层应加入桌面/全屏/台前调度，并避免随应用隐藏")
        window.setFrameOrigin(NSPoint(x: 100000, y: 100000))
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        precondition(NSScreen.screens.contains { $0.visibleFrame.contains(window.frame) },
                     "显示器布局变化后离屏窗口应回到现有屏幕内")

        print("PASS: 意外隐藏自愈、右上角归位、焦点保持、跨桌面策略")
        precondition(pc.debugStatusItem!.isVisible
                     && pc.debugStatusItem!.length == NSStatusItem.variableLength
                     && pc.debugStatusItem!.button!.title == "到期"
                     && pc.debugStatusItem!.button!.image != nil
                     && pc.debugStatusItem!.menu != nil,
                     "菜单栏入口必须请求显示沙漏和到期文字；实际呈现需在正式菜单栏复核")

        let menu = NSMenu()
        pc.menuWillOpen(menu)
        for _ in 0..<31 { pc.tick() }
        precondition(window.level == .floating, "菜单跟踪时心跳不得把覆盖层压到菜单上")
        pc.menuWillOpen(menu)
        pc.menuDidClose(menu)
        precondition(window.level == .floating && pc.debugCollapseGate.suppressed,
                     "嵌套菜单还有一层时应保持交互抑制")
        pc.menuDidClose(menu)
        precondition(window.level == FloatingWindowPolicy.panelLevel && !pc.debugCollapseGate.suppressed,
                     "菜单完全关闭后立即恢复置顶和自动收起")
        pc.perform(NSSelectorFromString("hideClicked"))
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        precondition(!window.isVisible, "主动隐藏应跨桌面仍被尊重")
        pc.restoreToTopRight()
        pc.debugSetExpanded(true)
        pc.perform(NSSelectorFromString("collapseClicked"))
        precondition(window.isVisible && window.frame.size == NSSize(width: 54, height: 18),
                     "顶部收起按钮应保留可见胶囊")
        print("PASS: 嵌套菜单层级恢复、主动隐藏保持、关闭改为收起")
        pc.debugSetExpanded(true)  // 还原空库首启引导，交给后续既有断言。
    }

    // applicationDidFinishLaunching 返回后，WindowServer 才完成首次挂窗。
    private func windowStackTest() {
        let window = pc.debugContentView!.window!
        let blocker = NSWindow(contentRect: window.frame.insetBy(dx: -20, dy: -20),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        blocker.isReleasedWhenClosed = false
        blocker.level = NSWindow.Level(rawValue: 102)
        blocker.orderFrontRegardless()
        window.displayIfNeeded()
        blocker.displayIfNeeded()
        CATransaction.flush()
        let stack = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let panelIndex = stack.firstIndex { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }
        let blockerIndex = stack.firstIndex { ($0[kCGWindowNumber as String] as? Int) == blocker.windowNumber }
        precondition(panelIndex != nil && blockerIndex != nil && panelIndex! < blockerIndex!,
                     "WindowServer 必须确认置顶面板压过后打开的系统覆盖层级窗口")
        blocker.orderOut(nil)
        print("PASS: WindowServer 确认真实窗口压过后打开的覆盖层窗口")
    }

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
        // 首次重置为日期文本框（DateTextField），按 accessibilityIdentifier 定位
        let firstResetField = descendants(splitEditor.window!.contentView!)
            .compactMap { $0 as? DateTextField }.first { $0.accessibilityIdentifier() == "firstResetField" }!
        let df = DateFormatter()
        df.dateFormat = "yyyy/MM/dd HH:mm"
        df.timeZone = .current
        firstResetField.setText(df.string(from: now.addingTimeInterval(7 * 86400)))
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

        // ── 日期文本框：前导零可键入（旧 NSDatePicker 会吞掉 0，无法输 07 分/07 日）──
        var zeroDraft = SubItem.manualDefault(name: "零头探针", vendor: "其他")
        zeroDraft.expiresAt = now.addingTimeInterval(3 * 86400)
        let zeroEditor = EditorSheetController(item: zeroDraft, isNew: false)
        let expiryField = descendants(zeroEditor.window!.contentView!)
            .compactMap { $0 as? DateTextField }.first { $0.accessibilityIdentifier() == "expiryField" }!
        expiryField.setText("2026/10/07 00:07")
        precondition(Calendar.current.component(.day, from: expiryField.date) == 7
                     && Calendar.current.component(.month, from: expiryField.date) == 10
                     && Calendar.current.component(.minute, from: expiryField.date) == 7,
                     "日期文本框必须能键入前导零（07 分、07 日）")
        expiryField.setText("不是日期")
        precondition(expiryField.date == Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 7, minute: 7))!,
                     "无效输入不得污染已生效日期")
        // 实际日期入口必须是可见按钮：从非法文本打开玻璃月历，选日后恢复合法值且保留时间。
        let calendarButton = descendants(zeroEditor.window!.contentView!)
            .compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "expiryFieldCalendarButton" }!
        zeroEditor.window!.orderFrontRegardless()
        calendarButton.performClick(nil)
        precondition(CalendarPickerController.shared.isVisible, "日期按钮必须打开月历")
        precondition(CalendarPickerController.shared.debugPanel!.level > pc.debugContentView!.window!.level,
                     "日历必须位于置顶面板上方")
        precondition(CalendarPickerController.shared.debugTap(year: 2026, month: 10, day: 8),
                     "月历日期格必须可点击")
        precondition(CalendarPickerController.shared.isVisible
                     && CalendarPickerController.shared.debugSelected != nil,
                     "点日只标记选中，必须等「确定」才提交（先看后确认）")
        precondition(CalendarPickerController.shared.debugConfirm(), "确定按钮必须存在且可点")
        let chosen = Calendar.current.dateComponents([.day, .hour, .minute], from: expiryField.date)
        precondition(!CalendarPickerController.shared.isVisible && chosen.day == 8
                     && chosen.hour == 0 && chosen.minute == 7
                     && DateTextField.parseDateText(expiryField.stringValue) != nil,
                     "从非法文本选日后应显示合法日期，且保留原时分")
        print("PASS: 玻璃月历按钮打开、点击日期、非法文本回填和时间保留")
        // 逐键键入模拟：光标在末尾，先敲 0 再敲 7 → 必须保留 07（回归：打 0 后打 7 变成 7）
        zeroEditor.window!.makeFirstResponder(expiryField)
        if let fe = zeroEditor.window!.fieldEditor(false, for: expiryField) {
            fe.selectedRange = NSRange(location: (expiryField.stringValue as NSString).length, length: 0)
            fe.insertText("0")
            fe.insertText("7")
        }
        precondition(expiryField.stringValue.hasSuffix("07"),
                     "逐键键入 0、7 必须得到 07，实际：\(expiryField.stringValue)")
        // 布局回归：日期框禁止折行且宽度足以单行放下整串（否则折叠成两行被裁）
        precondition((expiryField.cell as? NSTextFieldCell)?.wraps == false, "日期框必须禁止折行")
        precondition(expiryField.intrinsicContentSize.width >= 90, "日期框宽度必须容得下 yyyy/MM/dd HH:mm")
        print("PASS: 日期文本框前导零（07 分/07 日）可键入，无效输入不污染日期")

        // ── 日期文本框：键入过滤 + 严格解析（回归：往「天」里连敲 3333300 曾被 lenient 滚成 11153 年）──
        zeroEditor.window!.makeFirstResponder(nil)   // 结束上一段编辑会话
        expiryField.setText("2026/10/3")
        zeroEditor.window!.makeFirstResponder(expiryField)
        if let fe2 = zeroEditor.window!.fieldEditor(false, for: expiryField) {
            fe2.selectedRange = NSRange(location: (expiryField.stringValue as NSString).length, length: 0)
            for _ in 0..<6 { fe2.insertText("3") }   // 连敲 6 个 3：天段第 3 位起必须敲不进
            fe2.insertText("abc")                    // 垃圾字符必须被剔除
        }
        precondition(expiryField.stringValue == "2026/10/33",
                     "键入过滤：天段最多 2 位，实际：\(expiryField.stringValue)")
        zeroEditor.window!.makeFirstResponder(nil)
        let validExpiry = expiryField.date
        expiryField.setText("2026/10/3333300 20:34")
        precondition(expiryField.date == validExpiry,
                     "2026/10/3333300 不得被 lenient 进位滚动成 11153 年")
        expiryField.setText("2026/10/99 20:34")
        precondition(expiryField.date == validExpiry, "天段越界（99）不得进位滚到下月")
        expiryField.setText("2026/02/30 12:00")
        precondition(expiryField.date == validExpiry, "不存在的日期（2/30）不得静默进位")
        expiryField.setText("2026-10-7 8:5")
        precondition(expiryField.date == Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 8, minute: 5))!,
                     "单数字段与 - 分隔写法仍可解析")
        print("PASS: 日期框键入过滤（天段封顶/垃圾剔除）+ 严格解析（进位滚动/越界全拒）")

        // ── 分段时间输入：点选「时/分」段后数字个位→十位左移 ──
        // 进位规则本体（纯函数）：合并超上限就丢掉已敲的、以新数字重起个位
        func shifted(_ p: Int?, _ d: String, cap: Int) -> String { DateTextField.shift(pending: p, digits: d, cap: cap).written }
        precondition(shifted(nil, "1", cap: 23) == "1", "个位起敲 1 就显示 1（不提前补零）")
        precondition(shifted(1, "3", cap: 23) == "13", "1→3 左移成 13")
        precondition(shifted(9, "3", cap: 23) == "3", "9→3：93 超 23 → 丢 9 重起个位 3")
        precondition(shifted(2, "5", cap: 23) == "5", "2→5：25 超 23 → 5")
        precondition(shifted(5, "9", cap: 59) == "59", "分档上限 59，5→9 得 59")
        precondition(shifted(9, "9", cap: 59) == "9", "9→9：99 超 59 → 9")
        precondition(DateTextField.shift(pending: 3, digits: "3", cap: 23).pending == 3, "累计值随进位更新")
        // ←/→、Tab 的跳段顺序
        precondition(DateTextField.Segment.date.stepped(1) == .hour
                     && DateTextField.Segment.hour.stepped(1) == .minute
                     && DateTextField.Segment.minute.stepped(1) == .minute
                     && DateTextField.Segment.hour.stepped(-1) == .date,
                     "跳段顺序：日期→时→分，分不再往后")
        // 点到哪段选哪段（按字符位判定）
        let probe = "2026-11-01 13:13"
        precondition(DateTextField.segment(at: 3, in: probe) == .date
                     && DateTextField.segment(at: NSMaxRange(DateTextField.digitRuns(probe)[2]), in: probe) == .date
                     && DateTextField.segment(at: 12, in: probe) == .hour
                     && DateTextField.segment(at: 15, in: probe) == .minute,
                     "点选定位：日期段/时段/分段各归各")
        precondition(DateTextField.segment(at: 11, in: "2026-11-01 ") == .hour, "只敲了日期时点在尾部归「时」段")
        // 真走字段编辑器：点选「时」段 → 逐键 1、3 → 13；再 9、3 → 个位重起，失焦补零成 03
        expiryField.setText("2026-11-01 08:05")
        zeroEditor.window!.makeFirstResponder(expiryField)
        if let segEditor = expiryField.currentEditor() as? NSTextView {
            expiryField.selectSegment(.hour, in: segEditor)
            precondition(expiryField.segment == .hour
                         && segEditor.selectedRange == DateTextField.digitRuns(segEditor.string)[3],
                         "点选时段必须整段选中")
            segEditor.insertText("1")
            segEditor.insertText("3")
            precondition(expiryField.stringValue == "2026-11-01 13:05",
                         "时段逐键 1、3 必须左移成 13，实际：\(expiryField.stringValue)")
            segEditor.insertText("9")
            segEditor.insertText("3")
            precondition(expiryField.stringValue == "2026-11-01 3:05",
                         "时段 9、3 超上限须重起个位，实际：\(expiryField.stringValue)")
            zeroEditor.window!.makeFirstResponder(nil)   // 失焦 → 严格解析 + 补零规范化
            precondition(expiryField.stringValue == "2026-11-01 03:05",
                         "失焦后个位补零，实际：\(expiryField.stringValue)")
        } else {
            preconditionFailure("分段键入用例拿不到字段编辑器")
        }
        // 前导零分钟：点选「分」段敲 0、7 → 个位可见（03:7），失焦补零成 07
        //（旧 NSDatePicker 吞 0 的老坑，分段路径同样不能复现）
        zeroEditor.window!.makeFirstResponder(expiryField)
        if let minEditor = expiryField.currentEditor() as? NSTextView {
            expiryField.selectSegment(.minute, in: minEditor)
            minEditor.insertText("0")
            minEditor.insertText("7")
            precondition(expiryField.stringValue == "2026-11-01 03:7",
                         "分段键入过程中个位要看得见，实际：\(expiryField.stringValue)")
        }
        zeroEditor.window!.makeFirstResponder(nil)
        precondition(expiryField.stringValue == "2026-11-01 03:07",
                     "失焦补零规范化，实际：\(expiryField.stringValue)")
        precondition(Calendar.current.component(.minute, from: expiryField.date) == 7, "分段输入必须落到生效日期")
        print("PASS: 时/分段点选键入（个位→十位、超上限重起、失焦补零、前导零分钟）")

        // ── 缺陷复现 1：选「订阅 · 周额度重置」后不动「首次重置」默认值 → 保存被自己的默认值挡死 ──
        var weekDraft = SubItem.manualDefault(name: "锚点陷阱", vendor: "其他")
        weekDraft.expiresAt = now.addingTimeInterval(30 * 86400)
        let anchorEditor = EditorSheetController(item: weekDraft, isNew: true)
        failParent.beginSheet(anchorEditor.window!)
        let anchorPopup = descendants(anchorEditor.window!.contentView!)
            .compactMap { $0 as? NSPopUpButton }.first!
        anchorPopup.selectItem(at: 1)                     // 订阅 · 周额度重置（第k/n周）
        anchorEditor.perform(NSSelectorFromString("inputChanged"))   // 模拟用户点选档位
        let anchorField = descendants(anchorEditor.window!.contentView!)
            .compactMap { $0 as? DateTextField }.first { $0.accessibilityIdentifier() == "firstResetField" }!
        precondition(DateTextField.parseDateText(anchorField.stringValue).map { $0 <= weekDraft.expiresAt } == true,
                     "默认「首次重置」文本本身就必须不晚于到期，实际：\(anchorField.stringValue)")
        let formLabels = descendants(anchorEditor.window!.contentView!)
            .compactMap { $0 as? NSTextField }
            .filter { !$0.isEditable && !$0.isHidden && !$0.stringValue.isEmpty }
            .map { $0.stringValue }
            .first { !$0.isEmpty && !["名称", "类型", "到期时间", "首次重置", "供应商"].contains($0) } ?? ""
        snapshot(anchorEditor.window!.contentView!, path: "build/render/editor-weekly-default.png")
        var anchorArgument: Date?
        var anchorItem: SubItem?
        anchorEditor.onSave = { item, _, anchor in
            anchorItem = item; anchorArgument = anchor; return true
        }
        anchorEditor.perform(NSSelectorFromString("saveClicked"))
        precondition(anchorEditor.window!.sheetParent == nil,
                     "不动「首次重置」默认值时周额度重置必须可保存，实际表单被挡：\(formLabels)")
        precondition(anchorArgument != nil && anchorArgument! <= anchorItem!.expiresAt,
                     "默认首次重置锚点必须早于（或等于）订阅到期")
        precondition(!formLabels.contains("最多拆分 520 周，请检查首次重置和到期日期"),
                     "预览不得把「锚点晚于到期」报成拆分超上限：\(formLabels)")
        print("PASS: 周额度重置默认锚点可直接保存（预览/守卫一致）")

        // ── 缺陷复现 2：日期框留有非法文本时点保存 → 不得静默按上一有效日期落库并关表单 ──
        var staleDraft = SubItem.manualDefault(name: "非法文本探针", vendor: "其他")
        staleDraft.expiresAt = now.addingTimeInterval(5 * 86400)
        let staleEditor = EditorSheetController(item: staleDraft, isNew: false)
        failParent.beginSheet(staleEditor.window!)
        let staleField = descendants(staleEditor.window!.contentView!)
            .compactMap { $0 as? DateTextField }.first { $0.accessibilityIdentifier() == "expiryField" }!
        staleField.setText("2026/10/99 20:34")   // 显示非法、内部 date 仍是旧有效值
        var stalePipelineCalled = false
        staleEditor.onSave = { _, _, _ in stalePipelineCalled = true; return true }
        staleEditor.perform(NSSelectorFromString("saveClicked"))
        precondition(!stalePipelineCalled, "日期文本非法时不得进入保存管线（否则静默存旧日期）")
        precondition(staleEditor.window!.sheetParent != nil, "日期文本非法时表单必须保持打开")
        staleField.setText("2026/11/05 09:07")   // 修正为合法值后可保存
        staleEditor.perform(NSSelectorFromString("saveClicked"))
        precondition(stalePipelineCalled && staleEditor.window!.sheetParent == nil,
                     "改对日期后应正常保存并关闭")
        let staleParts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: staleField.date)
        precondition(staleParts.year == 2026 && staleParts.month == 11 && staleParts.day == 5
                     && staleParts.hour == 9 && staleParts.minute == 7,
                     "保存生效值必须等于修正后的文本，实际：\(staleField.stringValue)")
        print("PASS: 非法日期文本阻断保存并保持表单，修正后按文本生效")

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
        precondition(RowView.detailTooltip(qresetProbe, now: now).contains("提前 5 小时"), "tooltip 应说明默认提前量与右键入口")
        print("PASS: tooltip 按额度重置语义精确区分")

        panelAnchorTests()
        controlTests()
    }

    private func controlTests() {
        let floating = pc.debugContentView!.window!
        let existingWindows = Set(NSApp.windows.map(\.windowNumber))
        let anchor = NSPoint(x: floating.frame.maxX, y: floating.frame.maxY)
        pc.showControls()
        let controls = pc.debugControls
        func click(_ id: String) {
            let button = descendants(pc.debugContentView!).compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == id }!
            button.performClick(nil)
        }
        func action(_ id: String) {
            let item = controls.moreMenu.items.first { $0.accessibilityIdentifier() == id }!
            precondition(NSApp.sendAction(item.action!, to: item.target, from: item))
        }
        floating.contentView!.layoutSubtreeIfNeeded()
        precondition(floating.isVisible && floating.frame.width == 240 && controls.window === floating,
                     "控制区必须在原胶囊窗口内展开")
        precondition(Set(NSApp.windows.map(\.windowNumber)) == existingWindows,
                     "展开控制区不得创建另一个窗口")
        precondition(abs(floating.frame.maxX - anchor.x) < 1,
                     "打开控制区应沿用胶囊右缘，不得挪到屏幕中央")
        precondition(!controls.isHidden && controls.bounds.height == CapsuleControlsView.height,
                     "紧凑控制区必须可见")
        let buttons = descendants(controls).compactMap { $0 as? HoverEffectButton }
        precondition(buttons.count == 4 && Set(buttons.map { $0.frame.minY }).count == 1,
                     "控制功能必须排在同一行")
        precondition(buttons.allSatisfy { controls.bounds.contains($0.frame) },
                     "控制按钮不得溢出胶囊面板")
        controls.autoCollapseButton.performClick(nil)
        precondition(!Store.shared.state.panelAutoCollapse && !Store().state.panelAutoCollapse,
                     "手动模式必须跨重启保存")
        PanelController.debugCursorOverride = NSPoint(x: -100000, y: -100000)
        for _ in 0..<12 { pc.debugHeartbeatResync() }
        PanelController.debugCursorOverride = nil
        precondition(!pc.debugCollapseScheduled && floating.frame.width == 240,
                     "手动模式移开鼠标不得重挂自动收起")
        let controlFrame = floating.frame
        click("capsuleControlsToggle")
        precondition(controls.isHidden && floating.frame.height <= controlFrame.height,
                     "齿轮应在同一窗口内收起控制区")
        click("capsuleControlsToggle")
        precondition(!controls.isHidden && floating.frame == controlFrame,
                     "再次打开控制区应恢复原有位置与高度")
        action("panelControlHide")
        precondition(!floating.isVisible, "隐藏必须隐藏整个胶囊面板")
        pc.showControls()
        precondition(floating.isVisible && controls.window === floating && !controls.isHidden,
                     "主动打开应用必须恢复原胶囊内的控制区")
        let oldStatusItem = pc.debugStatusItem!
        let desktopFrame = floating.frame
        UserDefaults.standard.set(false, forKey: "NSStatusItem Visible AIReminderStatusItem")
        UserDefaults.standard.set(100000, forKey: "NSStatusItem Preferred Position AIReminderStatusItem")
        action("panelControlRestoreMenuBar")
        precondition(pc.debugStatusItem !== oldStatusItem && pc.debugStatusItem!.isVisible
                     && pc.debugStatusItem!.button!.image != nil,
                     "恢复顶部菜单栏应重新注册沙漏入口")
        precondition(UserDefaults.standard.integer(forKey: "NSStatusItem Preferred Position AIReminderStatusItem") == 519,
                     "恢复顶部菜单栏必须复位本应用原先保存的位置")
        precondition(floating.frame == desktopFrame && !Store.shared.state.panelCollapsed,
                     "恢复顶部菜单栏不得移动或收起当前面板")
        if let anotherScreen = NSScreen.screens.first(where: { $0 !== floating.screen }) {
            let frame = anotherScreen.visibleFrame
            floating.setFrameOrigin(NSPoint(x: frame.midX - 120, y: frame.maxY - floating.frame.height - 8))
            click("panelControlRestore")
            precondition(anotherScreen.visibleFrame.contains(floating.frame)
                         && abs(floating.frame.maxX - (frame.maxX - 6)) < 1,
                         "归位应留在胶囊所在显示器")
        }
        pc.showControls()
        snapshot(floating.contentView!, path: "build/render/panel_controls.png")
        click("panelControlCollapse")
        precondition(floating.isVisible && floating.frame.size == NSSize(width: 54, height: 18)
                     && controls.isHidden,
                     "收起必须让列表与控制区一起回到54×18胶囊")
        pc.pillClicked()
        precondition(floating.isVisible && controls.isHidden && controls.window === floating,
                     "点击胶囊应恢复列表，齿轮可再次打开同窗控制区")
        pc.showControls()
        click("panelControlCollapse")
        print("PASS: 胶囊同窗控制区、单行动作、齿轮开关、隐藏恢复、原位收起、多屏归位与手动模式")
    }

    /// AUDIT-2026-09-29 高影响问题：屏幕中部拖放的药丸一点就跳到屏幕右缘， chosen 位置丢失。
    private func panelAnchorTests() {
        print("ANCHOR: begin")
        pc.showPanel()
        pc.debugSetExpanded(false)
        guard let content = pc.debugContentView, let pw = content.window else {
            preconditionFailure("ANCHOR: 面板窗口未就绪 content=\(pc.debugContentView != nil)")
        }
        guard let vis = (pw.screen ?? NSScreen.main)?.visibleFrame else {
            preconditionFailure("ANCHOR: 取不到 visibleFrame，screen=\(String(describing: pw.screen))")
        }
        print("ANCHOR: window=\(pw.frame) vis=\(vis)")

        // ① 屏幕中部：展开必须保持药丸自己的右缘，收起后回到拖放位置
        let mid = NSPoint(x: vis.minX + 300, y: vis.minY + 400)
        pw.setFrameOrigin(mid)
        let pillRight = pw.frame.maxX
        let gestureContainer = content as! PanelContainerView
        let clickPoint = NSPoint(x: content.bounds.midX, y: content.bounds.midY)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: clickPoint,
                                     modifierFlags: [], timestamp: 0, windowNumber: pw.windowNumber,
                                     context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: clickPoint,
                                   modifierFlags: [], timestamp: 0.1, windowNumber: pw.windowNumber,
                                   context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
        gestureContainer.mouseDown(with: down)
        precondition(Store.shared.state.panelCollapsed, "按下胶囊不得抢先展开、吞掉拖动")
        gestureContainer.mouseUp(with: up)
        precondition(!Store.shared.state.panelCollapsed, "合法松开才展开胶囊")
        print("ANCHOR: 中部 expand 前右缘=\(pillRight) 展开后 frame=\(pw.frame)")
        precondition(pw.frame.width == 240, "点击药丸应展开面板，实际宽 \(pw.frame.width)")
        precondition(abs(pw.frame.maxX - pillRight) < 1,
                     "中部药丸展开应锚在自己的右缘 x=\(pillRight)，实际跳到 x=\(pw.frame.maxX)（偏 \(Int(pw.frame.maxX - pillRight)) pt）")
        precondition(pw.frame.minX >= vis.minX - 1, "展开面板左缘不得跑出可视区：\(pw.frame.minX) vs \(vis.minX)")
        pc.applyCollapsed(true)
        print("ANCHOR: 中部 collapse 后 origin=\(pw.frame.origin) 期望=\(mid)")
        precondition(pw.frame.origin == mid, "收起后药丸应留在拖放位置 \(mid)，实际跑到 \(pw.frame.origin)")

        // ② 贴屏幕右缘（原有默认位置）：展开/收起都必须待在原处
        let edge = NSPoint(x: vis.maxX - pw.frame.width, y: vis.minY + 300)
        pw.setFrameOrigin(edge)
        pc.pillClicked()
        print("ANCHOR: 贴边 expand frame=\(pw.frame) 期望右缘=\(vis.maxX)")
        precondition(pw.frame.width == 240, "贴边药丸也应展开")
        precondition(abs(pw.frame.maxX - vis.maxX) < 1, "贴右缘药丸展开后右缘仍应贴可视区右缘，实际 \(pw.frame.maxX) vs \(vis.maxX)")
        precondition(pw.frame.minX >= vis.minX, "贴边展开面板整块必须在可视区内")
        pc.applyCollapsed(true)
        precondition(pw.frame.origin == edge, "贴边收起后应留在 \(edge)，实际 \(pw.frame.origin)")

        // ③ 顶部位置保持：展开向下生长，不得把窗口顶到屏幕外
        let top = NSPoint(x: vis.midX, y: vis.maxY - 18)
        pw.setFrameOrigin(top)
        pc.pillClicked()
        print("ANCHOR: 顶部 expand frame=\(pw.frame) 期望顶边=\(top.y + 18)")
        precondition(abs(pw.frame.maxY - (top.y + 18)) < 1, "展开应保持顶边不动，实际顶边 \(pw.frame.maxY)")
        precondition(pw.frame.minY >= vis.minY - 1, "展开后面板不得掉到可视区下方之外：\(pw.frame.minY)")
        pc.applyCollapsed(true)

        // ④ 悬停记账：展开后光标仍在面板内 → 不许挂自动收起计时器；resize 引发的假
        //    mouseExited 同样不许挂（旧行为：面板 8 秒后从鼠标底下收走）；光标真离开 → 必须挂
        //    （旧行为：跳到右缘后既没 enter 也没 exit，面板永远卡着不收）。
        // 前面为截 panel_expanded.png 打开的内联编辑卡必须先关掉：编辑期间
        // scheduleAutoCollapse 有意不挂 8 秒表（本轮新行为），带着它跑这段会让
        // 「不许挂」的两条假通过、「必须挂」的那条假失败。
        pc.debugHideInlineEditor()
        precondition(pc.debugCollapseGate.editingId == nil, "④ 前置：内联编辑卡应已关闭")
        guard let container = pc.debugContentView as? PanelContainerView else {
            preconditionFailure("ANCHOR: contentView 不是 PanelContainerView")
        }
        let spot = NSPoint(x: vis.minX + 500, y: vis.minY + 400)
        pw.setFrameOrigin(spot)
        let pill = pw.frame
        PanelController.debugCursorOverride = NSPoint(x: pill.midX, y: pill.midY)
        pc.pillClicked()
        print("ANCHOR: 悬停展开后 frame=\(pw.frame) cursor=\(String(describing: PanelController.debugCursorOverride)) scheduled=\(pc.debugCollapseScheduled)")
        precondition(pw.frame.width == 240, "④ 前置：点击应展开")
        precondition(!pc.debugCollapseScheduled, "光标在面板内时点击展开不得挂自动收起计时器")
        container.onMouseExit?()
        precondition(!pc.debugCollapseScheduled, "光标仍在面板内的假 mouseExited 不得挂计时器（回归：8 秒后从鼠标底下收起）")
        PanelController.debugCursorOverride = NSPoint(x: pw.frame.minX - 120, y: pw.frame.minY - 120)
        container.onMouseExit?()
        print("ANCHOR: 光标离开后 gate=\(pc.debugCollapseGate)")
        precondition(pc.debugCollapseScheduled, "光标真正离开面板后必须挂上自动收起计时器")
        PanelController.debugCursorOverride = NSPoint(x: pw.frame.minX + 20, y: pw.frame.minY + 20)
        container.onMouseEnter?()
        precondition(!pc.debugCollapseScheduled, "光标回到面板内应取消自动收起")
        PanelController.debugCursorOverride = NSPoint(x: pill.midX, y: pill.midY)
        precondition(pw.frame.maxX == pill.maxX, "④ 展开仍应保持药丸自身右缘 \(pill.maxX)，实际 \(pw.frame.maxX)")
        PanelController.debugCursorOverride = nil
        pc.applyCollapsed(true)
        precondition(pw.frame.origin == spot, "④ 收尾：收起后应回到 \(spot)，实际 \(pw.frame.origin)")

        // ⑤ 心跳兜底：把窗口从静止光标底下拖走时，AppKit 一个 enter/exit 都不会发，
        //    旧行为是面板永远卡在展开态；tick 的重算必须把计时器挂回来。
        pw.setFrameOrigin(spot)
        PanelController.debugCursorOverride = NSPoint(x: spot.x + 27, y: spot.y + 9)
        pc.pillClicked()
        precondition(pw.frame.width == 240, "⑤ 前置：点击应展开")
        precondition(!pc.debugCollapseScheduled, "⑤ 前置：光标在面板内不得挂计时器")
        pw.setFrameOrigin(NSPoint(x: vis.minX + 900, y: vis.minY + 200))   // 模拟拖走（无鼠标事件）
        PanelController.debugCursorOverride = NSPoint(x: spot.x + 27, y: spot.y + 9)  // 光标留在原地
        pc.debugHeartbeatResync()
        precondition(pc.debugCollapseScheduled, "窗口被拖离静止光标后心跳必须挂上自动收起计时器")
        let fire = pc.debugCollapseFireDate
        precondition(fire != nil, "计时器必须有明确触发时刻")
        for _ in 0..<12 { pc.debugHeartbeatResync() }   // 模拟 12 次心跳
        precondition(pc.debugCollapseScheduled && pc.debugCollapseFireDate == fire,
                     "重复心跳不得把自动收起一路推迟（回归：永不收起），\(String(describing: fire)) → \(String(describing: pc.debugCollapseFireDate))")
        PanelController.debugCursorOverride = NSPoint(x: pw.frame.midX, y: pw.frame.midY)
        pc.debugHeartbeatResync()
        precondition(!pc.debugCollapseScheduled, "光标回到面板内应取消自动收起")
        PanelController.debugCursorOverride = nil
        pc.applyCollapsed(true)

        // ⑥ 高度封顶 + 滚动：行区超出可视预算时窗口必须限高在可视区内；
        //    滚轮能到底且最后一行完整可见；打开编辑卡增高内容后偏移保持合法；收起回位。
        let capTop = NSPoint(x: vis.minX + 300, y: vis.maxY - 18)
        pw.setFrameOrigin(capTop)
        for i in 1...40 {
            var it = SubItem.manualDefault(name: "填充行\(String(format: "%02d", i))", vendor: "其他")
            it.expiresAt = Date().addingTimeInterval(TimeInterval(i) * 20 * 3600) // 20 小时～800 小时，均 ≤ 34 天
            Store.shared.upsertManual(it)
        }
        pc.applyCollapsed(false)   // 数据有变强制重建展开（同时把滚动复位到顶）
        precondition(pw.frame.width == 240, "⑥ 前置：应处于展开态")
        precondition(pc.debugRowsContentH > pc.debugViewportH,
                     "⑥ 前置：40 行应溢出（content=\(pc.debugRowsContentH) viewport=\(pc.debugViewportH)）")
        precondition(pw.frame.height <= vis.height - 1,
                     "⑥ 窗口高度必须封顶在可视区内：\(pw.frame.height) vs vis \(vis.height)")
        precondition(pw.frame.minY >= vis.minY - 1,
                     "⑥ 窗口底部不得越过 Dock：\(pw.frame.minY) vs \(vis.minY)")
        precondition(pc.debugScrollIndicatorVisible, "⑥ 有溢出时必须显示滚动指示条")
        precondition(pc.debugScrollOffset == 0, "⑥ 展开应从顶部开始")
        snapshot(pc.debugContentView!, path: "build/render/panel_capped_40rows.png")
        pc.debugApplyScroll(-100000)
        let maxOffset = pc.debugRowsContentH - pc.debugViewportH
        precondition(abs(pc.debugScrollOffset - maxOffset) < 0.5,
                     "⑥ 向下滚动应钳制在最大偏移 \(maxOffset)，实际 \(pc.debugScrollOffset)")
        if let lastRect = pc.debugLastSubviewWindowRect {
            precondition(lastRect.minY >= -0.5 && lastRect.maxY <= pw.frame.height + 0.5,
                         "⑥ 滚到底后最后一行必须完整可见（窗口坐标 \(lastRect)，窗高 \(pw.frame.height)）")
        } else {
            preconditionFailure("⑥ 找不到行视图")
        }
        pc.debugApplyScroll(100000)
        precondition(pc.debugScrollOffset == 0, "⑥ 向上滚动应在顶部钳制为 0，实际 \(pc.debugScrollOffset)")
        pc.debugShowInlineEditor()
        precondition(pc.debugScrollOffset <= max(0, pc.debugRowsContentH - pc.debugViewportH),
                     "⑥ 编辑卡增高内容后偏移必须重新钳制")
        pc.applyCollapsed(true)
        precondition(pw.frame.height == 18, "⑥ 收起后必须恢复药丸尺寸，实际 \(pw.frame.height)")
        precondition(pw.frame.origin == capTop,
                     "⑥ 收起后应回到药丸原位 \(capTop)，实际 \(pw.frame.origin)")
        print("PASS: 展开锚定药丸自身右缘（中部/贴边/顶部），拖放位置不再被吞掉")
        print("PASS: 40 行面板高度封顶在可视区内，滚动到底可见最后一行，收起回位")

        // ⑦ 右键菜单可达 + ⟳ 刷新反馈：菜单必须挂在事件命中链上（旧实现挂在 hitTest 恒 nil 的
        //    effect 上，右键永远调不出）；⟳ 在刷新运行中置灰、结束恢复。
        pc.debugSetExpanded(false)
        guard let content7 = pc.debugContentView, let win7 = content7.window else {
            preconditionFailure("⑦ 前置：无面板窗口")
        }
        let menu = pc.debugContextMenu
        precondition(menu?.items.count == 6, "⑦ container 应持有 6 项右键菜单，实际 \(menu?.items.count ?? -1)")
        precondition(menu?.items.allSatisfy { $0.target != nil } == true, "⑦ 右键菜单项 target 必须已接线")
        let centerInWindow = content7.convert(NSPoint(x: content7.bounds.midX, y: content7.bounds.midY), to: nil)
        var hit: NSView? = win7.contentView?.hitTest(centerInWindow)
        var foundHost = false
        while let v = hit {
            if v.menu != nil { foundHost = true; break }
            hit = v.superview
        }
        precondition(foundHost, "⑦ 右键命中视图的响应链上必须存在持菜单宿主（右键可达）")
        let beforeCollapsed7 = Store.shared.state.panelCollapsed
        let toggleItem = menu?.items.first { $0.title == "展开 / 收起" }
        precondition(toggleItem != nil, "⑦ 菜单应有「展开 / 收起」项")
        if let idx = menu?.index(of: toggleItem!), idx >= 0 {
            menu?.performActionForItem(at: idx)
            precondition(Store.shared.state.panelCollapsed != beforeCollapsed7, "⑦ 菜单动作应切换展开状态")
        }
        pc.applyCollapsed(true)
        precondition(!pc.debugRefreshIndicatorOn, "⑦ 前置：非刷新态 ⟳ 应可用")
        pc.debugSetRefreshIndicator(true)
        precondition(pc.debugRefreshIndicatorOn, "⑦ 刷新运行中 ⟳ 应置灰")
        pc.debugSetRefreshIndicator(false)
        precondition(!pc.debugRefreshIndicatorOn, "⑦ 刷新结束 ⟳ 应恢复")
        print("PASS: 右键菜单挂在事件宿主上可达且动作生效，⟳ 刷新有置灰/恢复反馈")

        let reminderRow = RowView()
        var reminderProbe = SubItem.manualDefault(name: "提前提醒 UI 探针")
        reminderProbe.expiresAt = Date().addingTimeInterval(10 * 86400)
        reminderRow.configure(reminderProbe, now: Date())
        var selectedReminderID: String?
        reminderRow.onReminder = { selectedReminderID = $0.id }
        let reminderEvent = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: win7.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let reminderMenu = reminderRow.menu(for: reminderEvent)!
        precondition(reminderMenu.items[0].title == "提前 5 小时", "行右键显示该条当前提前量")
        reminderMenu.performActionForItem(at: 1)
        precondition(selectedReminderID == reminderProbe.id, "行右键入口必须选中该行 id")
        let reminderView = ReminderTimingView(item: reminderProbe, hours: 51)
        precondition(reminderView.daysField.stringValue == "2" && reminderView.hoursField.stringValue == "3",
                     "提醒设置按天/小时回填")
        reminderView.hoursField.stringValue = "24"
        precondition(reminderView.validHours == nil, "提醒表单拒绝 24 小时输入")
        reminderView.daysField.stringValue = "0"
        reminderView.hoursField.stringValue = "0"
        precondition(reminderView.validHours == nil, "提醒表单拒绝总提前量为 0")
        reminderView.perform(NSSelectorFromString("resetDefault"))
        precondition(reminderView.validHours == 5, "提醒表单恢复默认 5 小时")
        reminderView.daysField.stringValue = "2"
        reminderView.hoursField.stringValue = "3"
        reminderView.refreshPreview()
        snapshot(reminderView, path: "build/render/reminder_timing.png")
        let reminderController = ReminderTimingController(item: reminderProbe, hours: 51)
        precondition(reminderController.window?.contentView is GlassSurface, "提醒窗口应使用同主面板的系统液态玻璃宿主")
        precondition(reminderController.window!.level > pc.debugContentView!.window!.level,
                     "提前提醒设置窗口不得被置顶面板遮住")
        precondition(!reminderController.editor.daysField.drawsBackground && !reminderController.editor.hoursField.drawsBackground,
                     "天/小时输入框不得保留不透明系统底色")
        snapshot(reminderController.window!.contentView!, path: "build/render/reminder_glass_window.png")
        print("PASS: 单条右键提前提醒入口、天/小时回填、非法输入拦截与默认恢复")

        // ⑧ 编辑卡滚入视口：点视口下部的行时，卡片可能整体落在折叠区（用户像「点了没反应」），
        //    打开后必须自动平移进可视范围。
        pc.debugSetExpanded(true)
        let clip8 = descendants(pc.debugContentView!).compactMap { $0 as? RowsClipView }.first
        precondition(clip8 != nil, "⑧ 前置：找不到行区视口")
        let maxOff8 = pc.debugRowsContentH - pc.debugViewportH
        precondition(maxOff8 > 0, "⑧ 前置：40 行应保持溢出")
        pc.debugApplyScroll(-(maxOff8 / 2))   // 滚到一半
        var target8: (row: RowView, frame: CGRect)?
        for r in descendants(pc.debugContentView!).compactMap({ $0 as? RowView }).filter({ $0.item != nil }) {
            let f = clip8!.convert(r.frame, from: r.superview!)
            if f.minY >= 0 && f.maxY <= pc.debugViewportH,
               target8 == nil || f.maxY > target8!.frame.maxY {
                target8 = (r, f)
            }
        }
        precondition(target8 != nil, "⑧ 前置：应有完全可见的行")
        target8!.row.onOpen?(target8!.row.item!)
        let editor8 = descendants(pc.debugContentView!).compactMap { $0 as? InlineEditView }.first
        precondition(editor8 != nil, "⑧ 编辑卡应存在")
        let card8 = clip8!.convert(editor8!.frame, from: editor8!.superview!)
        precondition(card8.minY >= -0.5 && card8.maxY <= pc.debugViewportH + 0.5,
                     "⑧ 编辑卡必须滚入视口完整可见（card=\(card8)，viewport=\(pc.debugViewportH)）")
        // 状态行撑高后必须有人重排：否则「保存失败」这类提示会被裁在卡片里（曾经的实测回归）
        let cardH0 = editor8!.frame.height
        editor8!.showStatus("对齐同步失败：请检查网络", color: .systemRed, autoHide: false)
        let cardH1 = editor8!.intrinsicContentSize.height
        precondition(cardH1 > cardH0, "状态行出现时卡片固有高度必须增长（\(cardH0) → \(cardH1)）")
        precondition(editor8!.frame.height >= cardH1 - 0.5,
                     "onHeightChanged 未接线：卡片实高没跟上固有高度（\(editor8!.frame.height) vs \(cardH1)）")
        editor8!.clearStatus()
        precondition(editor8!.frame.height <= cardH0 + 0.5,
                     "状态清除后卡片应回落到原高（\(editor8!.frame.height) vs \(cardH0)）")
        print("PASS: 编辑卡状态行撑高即重排，提示不被裁切")
        target8!.row.onOpen?(target8!.row.item!)   // 再点同行收起
        precondition(descendants(pc.debugContentView!).compactMap { $0 as? InlineEditView }.first == nil,
                     "⑧ 再点同行应收起编辑卡")
        pc.applyCollapsed(true)
        print("PASS: 视口下部点开编辑卡自动滚入可视区，再点同行正常收起")

        // ──  行内副标题不得从 ✕ 底下穿过（曾经 subLabel.trailing 钉到行尾）──
        pc.applyCollapsed(false)          // 上一个用例收起过面板，这里要展开才有可见行
        pc.debugContentView?.layoutSubtreeIfNeeded()
        var checkedRows = 0, overlapped = 0
        for row in descendants(pc.debugContentView!).compactMap({ $0 as? RowView }) {
            guard row.frame.width > 10, !row.isHidden else { continue }
            // 副标题的判据：文案形如「供应商 · 到期时间 · 来源」；✕ 是行内唯一按钮。
            // 两者都是 row 的直接子视图，frame 同坐标系，可直接比左右缘。
            let labels = descendants(row).compactMap { $0 as? NSTextField }
            guard let sub = labels.first(where: { !$0.isHidden && $0.stringValue.contains(" · ") }),
                  let del = descendants(row).compactMap({ $0 as? NSButton }).first else { continue }
            checkedRows += 1
            if sub.frame.maxX > del.frame.minX + 0.5 {
                overlapped += 1
                print("  行 \(row.item?.name ?? "?")：副标题右缘 \(sub.frame.maxX) > ✕ 左缘 \(del.frame.minX)")
            }
        }
        precondition(checkedRows > 0, "⑨ 前置：应能检查到带副标题的行")
        precondition(overlapped == 0, "⑨ \(overlapped)/\(checkedRows) 行的副标题压到了删除按钮")
        print("PASS: 副标题止于 ✕ 之前（\(checkedRows) 行）")

        // ── 展示窗口：80 天的条目留在库里，面板和设置表都不排出来 ──
        var far = SubItem.manualDefault(name: "八十天后", vendor: "其他")
        far.expiresAt = Date().addingTimeInterval(80 * 86400)
        Store.shared.upsertManual(far)
        var soon = SubItem.manualDefault(name: "十天后", vendor: "其他")
        soon.expiresAt = Date().addingTimeInterval(10 * 86400)
        Store.shared.upsertManual(soon)
        pc.applyCollapsed(false)
        let rowNames = descendants(pc.debugContentView!).compactMap { ($0 as? RowView)?.item?.name }
        precondition(rowNames.contains("十天后"),
                     "面板行应出现「十天后」，实际：\(rowNames.joined(separator: "、"))")
        precondition(!rowNames.contains("八十天后"),
                     "面板行不得出现「八十天后」，实际：\(rowNames.joined(separator: "、"))")
        precondition(Store.shared.manualItems.contains { $0.name == "八十天后" },
                     "「八十天后」必须仍在库里，只是不展示")
        pc.openSettingsWindow()
        func settingsTable(in window: NSWindow?) -> NSTableView? {
            guard let content = window?.contentView else { return nil }
            return descendants(content).compactMap { $0 as? NSTableView }.first
        }
        // 前面截图另开过一个设置窗，表格可能是旧的；刚 orderFront 的这一扇才是本次数据。
        let frontSettings = NSApp.orderedWindows.first { settingsTable(in: $0) != nil }
        guard let table = settingsTable(in: frontSettings) else {
            preconditionFailure("openSettingsWindow 之后，从窗口 contentView 递归找不到 NSTableView")
        }
        guard let dataSource = table.dataSource else {
            preconditionFailure("设置表格没有 dataSource，无法读每行 objectValue")
        }
        var tableLines: [String] = []
        for row in 0..<table.numberOfRows {
            var cells: [String] = []
            for col in table.tableColumns {
                if let value = dataSource.tableView?(table, objectValueFor: col, row: row) {
                    cells.append(String(describing: value))
                }
            }
            tableLines.append(cells.joined(separator: "\t"))
        }
        let tableText = tableLines.joined(separator: "\n")
        let tableHead = String(tableText.prefix(80))
        precondition(tableText.contains("十天后"),
                     "设置表格应有「十天后」，行数 \(table.numberOfRows)，前 80 字：\(tableHead)")
        precondition(!tableText.contains("八十天后"),
                     "设置表格不得出现「八十天后」，行数 \(table.numberOfRows)，前 80 字：\(tableHead)")
        print("PASS: 80 天条目留在库里，面板和设置表只显示 40 天内")

        // ── 展示天数可改：15 天不显示 20 天条目；非法输入不覆盖已保存的天数 ──
        guard let horizonWindow = frontSettings, let horizonRoot = horizonWindow.contentView else {
            preconditionFailure("openSettingsWindow 之后没有设置窗，无法找 displayHorizonField")
        }
        guard let horizonField = descendants(horizonRoot).compactMap({ $0 as? NSTextField })
            .first(where: { $0.identifier?.rawValue == "displayHorizonField" }) else {
            let title = horizonWindow.title.isEmpty ? "无标题" : horizonWindow.title
            let ident = horizonWindow.identifier?.rawValue ?? "无 identifier"
            let banner = descendants(horizonRoot).compactMap { $0 as? NSTextField }
                .first { $0.stringValue.contains("设置后台") }?.stringValue ?? "无「设置后台」文案"
            preconditionFailure("在设置窗 windowNumber=\(horizonWindow.windowNumber) title=\(title) identifier=\(ident) 文案=\(banner) 的 contentView 里找不到 identifier 为 displayHorizonField 的 NSTextField")
        }
        guard let horizonController = table.dataSource as? NSObject else {
            preconditionFailure("设置表格 dataSource 不是 NSObject，无法调用 horizonEdited（窗 windowNumber=\(horizonWindow.windowNumber)）")
        }
        // 名称列精确匹配：「二十天后」含有子串「十天后」，不能用整表文本 contains。
        func settingsNames(_ tableView: NSTableView) -> [String] {
            guard let source = tableView.dataSource else {
                preconditionFailure("设置表格没有 dataSource，无法读每行 objectValue")
            }
            guard let nameCol = tableView.tableColumns.first(where: { $0.identifier.rawValue == "name" }) else {
                preconditionFailure("设置表格没有 name 列，无法核对条目名")
            }
            var names: [String] = []
            for row in 0..<tableView.numberOfRows {
                if let value = source.tableView?(tableView, objectValueFor: nameCol, row: row) {
                    names.append(String(describing: value))
                }
            }
            return names
        }
        func commitHorizon(_ text: String) {
            horizonField.stringValue = text
            _ = horizonController.perform(NSSelectorFromString("horizonEdited"))
        }
        commitHorizon("15")
        let namesAt15 = settingsNames(table)
        precondition(namesAt15.contains("十天后"),
                     "15 天窗口仍应显示「十天后」，实际：\(namesAt15.joined(separator: "、"))")
        precondition(!namesAt15.contains("八十天后"),
                     "15 天窗口不得显示「八十天后」，实际：\(namesAt15.joined(separator: "、"))")
        var twentyDay = SubItem.manualDefault(name: "二十天后", vendor: "其他")
        twentyDay.expiresAt = Date().addingTimeInterval(20 * 86400)
        Store.shared.upsertManual(twentyDay)
        // upsert 不刷新设置表（表只在 horizonEdited 和 1 秒 ticker 里重载）。天数没变时再送一次 15。
        commitHorizon("15")
        let namesFiltered = settingsNames(table)
        let filteredList = namesFiltered.joined(separator: "、")
        precondition(namesFiltered.contains("十天后"),
                     "15 天窗口应有「十天后」，实际：\(filteredList)")
        precondition(!namesFiltered.contains("二十天后"),
                     "15 天窗口不得出现「二十天后」，实际：\(filteredList)")
        precondition(!namesFiltered.contains("八十天后"),
                     "15 天窗口不得出现「八十天后」，实际：\(filteredList)")
        precondition(Store.shared.manualItems.contains { $0.name == "二十天后" },
                     "「二十天后」必须仍在库里，只是不展示")
        precondition(Store.shared.manualItems.contains { $0.name == "八十天后" },
                     "「八十天后」必须仍在库里，只是不展示")
        commitHorizon("abc")
        precondition(horizonField.stringValue == "15",
                     "非法输入不改已保存的天数，字段应回到 15，实际「\(horizonField.stringValue)」")
        precondition(Store.shared.displayHorizonDays == 15,
                     "非法输入后 displayHorizonDays 应仍为 15，实际 \(Store.shared.displayHorizonDays)")
        commitHorizon("40")
        let restoredDays = Store.shared.displayHorizonDays
        precondition(restoredDays == 40,
                     "恢复后 displayHorizonDays 应为 40，实际 \(restoredDays)")
        let namesRestored = settingsNames(table)
        precondition(namesRestored.contains("二十天后"),
                     "40 天窗口应重新显示「二十天后」，实际：\(namesRestored.joined(separator: "、"))")
        print("PASS: 展示天数可改，非法输入保持 15，恢复后天数 \(restoredDays)")

        // ── 长排期预览必须折行，不得把编辑窗口拉成一条横贯屏幕的长条（不保存）──
        // 日期行 + 快捷按钮 layout 之后大约 509 宽，所以不能拿初始的 430 当上限。
        // 560 是 contentMaxSize：再宽就是排期文字把窗口撑开了。
        var longDraft = SubItem.manualDefault(name: "长排期", vendor: "其他")
        longDraft.expiresAt = Date().addingTimeInterval(300 * 86400)
        let longEditor = EditorSheetController(item: longDraft, isNew: true)
        let longParent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 20, height: 20),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        longParent.beginSheet(longEditor.window!)
        let longPopup = descendants(longEditor.window!.contentView!).compactMap { $0 as? NSPopUpButton }.first!
        longPopup.selectItem(at: 1)   // 订阅 · 周额度重置（第k/n周）
        let longFirst = descendants(longEditor.window!.contentView!)
            .compactMap { $0 as? DateTextField }.first { $0.accessibilityIdentifier() == "firstResetField" }!
        let longDF = DateFormatter()
        longDF.dateFormat = "yyyy/MM/dd HH:mm"
        longDF.timeZone = .current
        longFirst.setText(longDF.string(from: Date().addingTimeInterval(7 * 86400)))
        longEditor.perform(NSSelectorFromString("inputChanged"))
        longEditor.window!.contentView!.layoutSubtreeIfNeeded()
        snapshot(longEditor.window!.contentView!, path: "build/render/editor-long-schedule.png")
        let previewLabels = descendants(longEditor.window!.contentView!).compactMap { $0 as? NSTextField }
        guard let preview = previewLabels.first(where: { $0.stringValue.hasPrefix("排期共") }) else {
            preconditionFailure("找不到以「排期共」开头的预览标签")
        }
        let previewHead = String(preview.stringValue.prefix(80))
        let contentW = longEditor.window!.contentView!.frame.width
        precondition(contentW <= 560,
                     "长排期不得把编辑窗口拉宽，实际宽 \(contentW)，预览：\(previewHead)")
        precondition(preview.stringValue.contains("\n"),
                     "周排期预览必须折行，实际宽 \(contentW)，预览：\(previewHead)")
        precondition(preview.frame.width <= contentW - 40,
                     "排期预览必须留在列内，实际宽 \(preview.frame.width)，窗口 \(contentW)，预览：\(previewHead)")
        precondition((preview.cell as? NSTextFieldCell)?.wraps == true,
                     "排期预览必须允许折行，实际宽 \(preview.frame.width)，预览：\(previewHead)")
        print("PASS: 长排期预览折行，编辑窗口宽 \(contentW)")
        // 这张表单不保存，sheet 会一直挂着。不收掉的话 NSApp.terminate 退不出去。
        if let sheet = longEditor.window {
            longParent.endSheet(sheet)
            sheet.orderOut(nil)
        }
        longParent.orderOut(nil)
    }
}

// 渲染测试会写入演示记录；裸跑二进制时必须在接触 Store 前拒绝正式数据目录。
setvbuf(stdout, nil, _IONBF, 0)   // 断言 trap 时不得丢失已打印的进度
setvbuf(stderr, nil, _IONBF, 0)
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
