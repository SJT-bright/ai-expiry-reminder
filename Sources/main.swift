import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panelController: PanelController?
    private var tickTimer: Timer?
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 常驻：接管单实例 + 确保 LaunchAgent（登录自启 + 被杀/退出后自动重启）
        Resident.acquireSingleInstance()
        if CommandLine.arguments.contains("--no-agent") {
            // 关闭常驻时以脱离模式重启的实例：移除 LaunchAgent 后不受守护运行
            Resident.disableNow()
        } else {
            Resident.install()
        }

        panelController = PanelController()
        panelController?.showPanel()

        // 命令行 `--settings`：启动时直接打开设置后台
        if CommandLine.arguments.contains("--settings") {
            panelController?.openSettingsWindow()
        }

        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.panelController?.tick()
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.panelController?.refreshData()
        }
        if let t = tickTimer { RunLoop.main.add(t, forMode: .common) }
        if let t = refreshTimer { RunLoop.main.add(t, forMode: .common) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Resident.releaseSingleInstance()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
