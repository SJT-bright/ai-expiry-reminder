import AppKit

// 离屏渲染自测：把悬浮窗（展开/收起）、设置后台、添加表单渲染成 PNG 供人工检查。
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
                                                      alertBeforeMinutes: 15, usedPercent: 100, groupID: nil))

        pc = PanelController(loadOfficialData: false)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            // 1) 展开态（仅隔离演示条目）
            self.pc.debugSetExpanded(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.pc.debugShowInlineEditor()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    precondition(self.pc.debugContentView!.bounds.width > 100)
                    snapshot(self.pc.debugContentView!, path: "build/render/panel_expanded.png")
                // 2) 收起态（贴边药丸）
                self.pc.debugSetExpanded(false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    snapshot(self.pc.debugContentView!, path: "build/render/panel_pill.png")
                    // 3) 设置后台
                    let sc = SettingsWindowController(panel: self.pc)
                    sc.showWindow(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        sc.debugPrintGeometry()
                        snapshot(sc.windowRef!.contentView!, path: "build/render/settings.png")
                        // 4) 添加表单
                        var example = SubItem.manualDefault(name: "ZCode", vendor: "ZCode")
                        let f = DateFormatter()
                        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
                        f.dateFormat = "yyyy-MM-dd HH:mm"
                        example.expiresAt = f.date(from: "2026-09-11 15:53")!
                        let editor = EditorSheetController(item: example, isNew: true)
                        func descendants(_ view: NSView) -> [NSView] {
                            [view] + view.subviews.flatMap { descendants($0) }
                        }
                        let controls = descendants(editor.window!.contentView!)
                        let pickers = controls.compactMap { $0 as? NSDatePicker }
                        let expiry = pickers.first { $0.action == NSSelectorFromString("expiryChanged") }!
                        let reset = pickers.first { $0 !== expiry }!
                        precondition(reset.dateValue == f.date(from: "2026-09-18 15:53")!, "首次重置必须从到期日+7天")
                        expiry.dateValue = f.date(from: "2026-09-12 15:53")!
                        editor.perform(NSSelectorFromString("expiryChanged"))
                        precondition(reset.dateValue == f.date(from: "2026-09-19 15:53")!, "改到期日应同步平移")
                        expiry.dateValue = example.expiresAt
                        editor.perform(NSSelectorFromString("expiryChanged"))
                        let checkbox = controls.compactMap { $0 as? NSButton }.first { $0.title.contains("周期重置") }!
                        checkbox.state = .on
                        editor.onSave = { Store.shared.upsertManual($0).saved }
                        editor.perform(NSSelectorFromString("saveClicked"))
                        let savedReset = Store.shared.manualItems.first { $0.id == "qreset:" + example.id }!
                        precondition(savedReset.expiresAt == f.date(from: "2026-09-18 15:53")!)
                        let reopened = EditorSheetController(item: example, isNew: false)
                        let reopenedReset = descendants(reopened.window!.contentView!).compactMap { $0 as? NSDatePicker }.first { $0.action != NSSelectorFromString("expiryChanged") }!
                        precondition(reopenedReset.dateValue == savedReset.expiresAt, "重新编辑不能倒退七天")
                        reopened.onSave = { _ in true }
                        reopened.perform(NSSelectorFromString("saveClicked"))
                        precondition(Store.shared.manualItems.first { $0.id == savedReset.id }!.expiresAt == savedReset.expiresAt)
                        print("PASS: 编辑表单首次锚点、平移、保存及重新编辑")

                        // ── 文案识别范围：额度重置窗口称「重置」，手动通用周期窗口仍称「到期」 ──
                        let qresetProbe = SubItem(id: "qreset:探针", name: "探针·周重置", vendor: "探针",
                                                  kind: .window, expiresAt: now.addingTimeInterval(3600),
                                                  repeatHours: 168, source: "manual", note: "",
                                                  alertBeforeMinutes: 60, usedPercent: nil, groupID: nil)
                        let autoProbe = SubItem(id: "auto:probe:300", name: "探针·5小时窗口", vendor: "OpenAI",
                                                kind: .window, expiresAt: now.addingTimeInterval(3600),
                                                repeatHours: 5, source: "codex", note: "",
                                                alertBeforeMinutes: 15, usedPercent: 40, groupID: nil)
                        var manualWindow = SubItem.manualDefault(name: "月付续费日")
                        manualWindow.kind = .window
                        manualWindow.repeatHours = 720
                        precondition(AlertEngine.composeMessage([qresetProbe]).contains("重置（"), "周重置伴生窗口通知应称重置")
                        precondition(AlertEngine.composeMessage([autoProbe]).contains("重置（"), "官方额度窗口通知应称重置")
                        precondition(!AlertEngine.composeMessage([manualWindow]).contains("重置"), "手动通用窗口不得称重置")
                        precondition(AlertEngine.composeMessage([manualWindow]).contains("到期（"), "手动通用窗口通知仍称到期")
                        precondition(RowView.detailTooltip(qresetProbe, now: now).contains("下次重置"), "周重置伴生窗口 tooltip 应称下次重置")
                        precondition(!RowView.detailTooltip(manualWindow, now: now).contains("下次重置"), "手动通用窗口 tooltip 不得称下次重置")
                        print("PASS: 通知与 tooltip 按额度重置语义精确区分")

                        // ── 保存失败：表单不关闭、输入保留、文案可断言 ──
                        EditorSheetController.showsSaveFailureAlerts = false
                        let failParent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 20, height: 20),
                                                  styleMask: [.titled], backing: .buffered, defer: false)
                        let failEditor = EditorSheetController(item: example, isNew: false)
                        failParent.beginSheet(failEditor.window!)
                        let failName = descendants(failEditor.window!.contentView!)
                            .compactMap { $0 as? NSTextField }
                            .first { $0.placeholderString?.contains("Grok 重置卡") == true }!
                        failName.stringValue = "失败探针"
                        failEditor.onSave = { _ in false }
                        failEditor.perform(NSSelectorFromString("saveClicked"))
                        precondition(failParent.isSheet, "保存失败时表单必须保持打开")
                        precondition(failName.stringValue == "失败探针", "保存失败时输入必须原样保留")
                        precondition(EditorSheetController.lastSaveFailureMessage == "保存失败", "失败文案应可断言")
                        // 成功路径恢复：表单正常关闭、条目落库
                        failEditor.onSave = { Store.shared.upsertManual($0).saved }
                        failEditor.perform(NSSelectorFromString("saveClicked"))
                        precondition(!failParent.isSheet, "成功后表单正常关闭")
                        precondition(Store.shared.manualItems.contains { $0.name == "失败探针" }, "恢复成功路径后条目已保存")
                        print("PASS: 保存失败表单保留输入、成功路径正常关闭")

                        // ── 部分失败边界：父保存成功、周重置同步失败 → 不得报全部成功 ──
                        let partialParent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 20, height: 20),
                                                     styleMask: [.titled], backing: .buffered, defer: false)
                        let partialEditor = EditorSheetController(item: example, isNew: false)
                        partialParent.beginSheet(partialEditor.window!)
                        partialEditor.onSave = { _ in true }
                        partialEditor.quotaResetSyncOverride = { _, enabled, _ in !enabled }   // 启用重置时模拟写失败
                        partialEditor.perform(NSSelectorFromString("saveClicked"))
                        precondition(!partialParent.isSheet, "部分失败时主条目已保存、表单关闭")
                        precondition(EditorSheetController.lastSaveFailureMessage?.contains("未能更新") == true, "部分失败必须明确区分于全部成功")
                        EditorSheetController.showsSaveFailureAlerts = true
                        print("PASS: 部分失败边界明确（父成功+派生失败不报全部成功）")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            snapshot(editor.window!.contentView!, path: "build/render/editor.png")
                            NSApp.terminate(nil)
                        }
                    }
                }
                }
            }
        }
    }
}

let app = NSApplication.shared
let d = TestDelegate()
app.delegate = d
app.setActivationPolicy(.accessory)
ProcessInfo.processInfo.disableAutomaticTermination("render test")   // 绕开 LS 同步上报（裸进程会卡）
app.disableRelaunchOnLogin()
app.run()
