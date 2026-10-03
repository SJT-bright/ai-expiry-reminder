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
        // ⑦ 首用引导：必须在播种前以空库走一次真实 showPanel——
        //    新用户第一眼应该看到自动展开的「暂无条目，点 ＋ 添加」，而不是裸 ⏳ 药丸
        pc = PanelController(loadOfficialData: false)
        pc.showPanel()
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
        precondition(CalendarPickerController.shared.debugTap(year: 2026, month: 10, day: 8),
                     "月历日期格必须可点击")
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
        precondition(!RowView.detailTooltip(qresetProbe, now: now).contains("提醒"), "提醒功能已删除，tooltip 不得再出现提醒字样")
        print("PASS: tooltip 按额度重置语义精确区分")

        panelAnchorTests()
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
            it.expiresAt = Date().addingTimeInterval(TimeInterval(86400 * (i + 1)))
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
    }
}

// 渲染测试会写入演示记录；裸跑二进制时必须在接触 Store 前拒绝正式数据目录。
setvbuf(stdout, nil, _IONBF, 0)   // 断言 trap 时不得丢失已打印的进度
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
