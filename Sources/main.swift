import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panelController: PanelController?
    private var tickTimer: Timer?
    private var refreshTimer: Timer?

    /// 防 App Nap 的活动令牌（问题 5）：以前写成 `_ = beginActivity(...)`，令牌在这个
    /// full-expression 结束就被 ARC 释放，活动瞬间结束 —— 等于没写，玻璃照样被降级成磨砂。
    /// 现在作为常驻属性由 AppDelegate 持有，进程活着就不放；释放即自动结束活动。
    /// 选项用 .userInitiatedAllowingIdleSystemSleep：保持 UI 不被节流（亮屏、面板动画、
    /// 60s 刷新不被降级），但不再阻止系统休眠 —— 常驻 App 不该挡住合盖/睡眠。
    private let renderActivity: NSObjectProtocol = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiatedAllowingIdleSystemSleep],
        reason: "液态玻璃持续渲染")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 常驻：接管单实例（flock，见 Resident）+ 确保 LaunchAgent。
        // install() 只同步写 plist，launchctl 的 print/bootstrap/kickstart 在后台队列跑，
        // 主线程不再被 waitUntilExit 卡住（问题 6）。
        Resident.acquireSingleInstance()
        if Resident.isEnabledByUser {
            Resident.install()
        }

        panelController = PanelController()
        panelController?.showPanel()
        if CommandLine.arguments.contains("--restore-panel") { panelController?.restoreToTopRight() }
        if CommandLine.arguments.contains("--restore-menu-bar") { panelController?.restoreMenuBarItem() }
        buildMainMenu()
        // 主动打开应用时在原胶囊中展开控制区，不创建独立控制窗口。
        if !CommandLine.arguments.contains("--agent") { panelController?.showControls() }

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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panelController?.showControls()
        return true
    }

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let menu = NSMenu(title: "AI到期提醒")
        let control = menu.addItem(withTitle: "展开胶囊控制", action: #selector(PanelController.showControls), keyEquivalent: "1")
        control.target = panelController
        let restoreMenuBar = menu.addItem(withTitle: "恢复顶部菜单栏图标", action: #selector(PanelController.restoreMenuBarItem), keyEquivalent: "2")
        restoreMenuBar.target = panelController
        let settings = menu.addItem(withTitle: "管理记录…", action: #selector(PanelController.openSettingsWindow), keyEquivalent: ",")
        settings.target = panelController
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 AI到期提醒", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = menu
        main.addItem(appItem)
        NSApp.mainMenu = main
    }
}

if CommandLine.arguments.contains("--disable-resident-helper") {
    Resident.runDisableHelper()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
