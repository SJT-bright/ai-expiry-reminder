import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panelController: PanelController?
    private var tickTimer: Timer?
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 防 App Nap：后台静置时系统会把玻璃渲染降级成廉价模糊（用户实测的「磨砂化」截图）。
        // 常驻悬浮窗属于持续可见 UI，明确声明用户发起级活动，全程保持液态玻璃渲染。
        _ = ProcessInfo.processInfo.beginActivity(options: [.userInitiated],
                                                  reason: "液态玻璃持续渲染")
        // 常驻：接管单实例 + 确保 LaunchAgent（登录自启 + 被杀/退出后自动重启）
        Resident.acquireSingleInstance()
        if Resident.isEnabledByUser {
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

if CommandLine.arguments.contains("--disable-resident-helper") {
    Resident.runDisableHelper()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
