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

        pc = PanelController()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            // 1) 展开态（含官方数据 3 条 + 演示 3 条）
            self.pc.debugSetExpanded(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.pc.debugShowInlineEditor()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    snapshot(self.pc.debugContentView!, path: "build/render/panel_expanded.png")
                }
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
                        let editor = EditorSheetController(item: .manualDefault(), isNew: true)
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

let app = NSApplication.shared
let d = TestDelegate()
app.delegate = d
app.setActivationPolicy(.accessory)
ProcessInfo.processInfo.disableAutomaticTermination("render test")   // 绕开 LS 同步上报（裸进程会卡）
app.disableRelaunchOnLogin()
app.run()
