import AppKit

// CUA 原生端到端验收入口。复用正式 UI/Store，独立 bundle、数据目录，不接管正式实例。
let acceptanceData = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("ui-acceptance-data")
setenv("AR_DATA_DIR", acceptanceData.path, 1)
final class AcceptanceDelegate: NSObject, NSApplicationDelegate {
    var panel: PanelController!
    var timer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Store.shared.manualItems.isEmpty {
            var item = SubItem.manualDefault(name: "E2E 长倒计时", vendor: "其他")
            item.expiresAt = Date().addingTimeInterval(23 * 3600 + 59 * 60)
            Store.shared.upsertManual(item)
        }
        Store.shared.state.panelCollapsed = true
        Store.shared.state.autoExpandDone = true
        panel = PanelController(loadOfficialData: false)
        panel.showPanel()
        if let window = panel.debugContentView?.window, let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY))
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.panel.tick() }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
}
let app = NSApplication.shared
let delegate = AcceptanceDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
