import Foundation
import AppKit

// MARK: - 常驻管理（LaunchAgent）
//
// 设计：
// - launchd 以 `--agent` 参数拉起应用（RunAtLoad 登录自启 + KeepAlive=true 无条件保活）
// - 手动打开的实例（无 --agent）在 install() 时 kickstart -k 把生命周期移交给 launchd，
//   launchd 的新实例通过「新实例接管」终止旧实例，最终收敛为 launchd 持有的单实例
// - 被强杀/崩溃 → launchd 立即重启；菜单「退出」也会被立即重启（真常驻）
// - 彻底关闭：独立 helper 注销 job 并重开普通实例；关闭偏好在以后手动启动时继续生效

enum Resident {
    static let label = "com.sijunting.ai-expiry-reminder"
    private static let disabledKey = "residentDisabled"

    static var isEnabledByUser: Bool {
        !UserDefaults.standard.bool(forKey: disabledKey)
    }

    static var isAgentSpawn: Bool {
        CommandLine.arguments.contains("--agent")
    }

    /// 规范安装位置：/Applications 优先（常驻 plist 永远指向它，避免双副本打架）
    static var appPath: String {
        let candidates = ["/Applications/AI到期提醒.app",
                          Bundle.main.bundleURL.path]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
            ?? Bundle.main.bundleURL.path
    }

    static var binaryPath: String {
        appPath + "/Contents/MacOS/AIReminder"
    }

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist", isDirectory: false)
    }

    // MARK: 状态

    static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func isLoaded() -> Bool {
        runLaunchctl(["print", "gui/\(getuid())/\(label)"])
    }

    // MARK: 安装 / 移除

    static func plistXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binaryPath)</string>
                <string>--agent</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>ProcessType</key><string>Background</string>
            <key>StandardOutPath</key><string>/tmp/aireminder.log</string>
            <key>StandardErrorPath</key><string>/tmp/aireminder.log</string>
        </dict>
        </plist>
        """
    }

    /// 确保常驻。agent 实例只写 plist；手动实例负责引导/移交。
    @discardableResult
    static func install() -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let xml = plistXML()
        let existing = try? String(contentsOf: plistURL, encoding: .utf8)
        let unchanged = (existing == xml)
        guard (try? xml.write(to: plistURL, atomically: true, encoding: .utf8)) != nil else { return false }

        if isAgentSpawn {
            // 我就是 launchd 拉起的实例，job 必然在运行，无需引导
            return true
        }
        if !isLoaded() {
            return bootstrap()
        }
        if !unchanged {
            // 定义有更新：重启 job（kickstart -k 终止旧 job 进程并立即拉起新的）
            kickstart()
        }
        return true
    }

    /// launchd 会结束自己的 job 进程，因此由独立 helper 完成注销和普通实例重启。
    @discardableResult
    static func uninstallViaDetach() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binaryPath)
        p.arguments = ["--disable-resident-helper"]
        do { try p.run(); return true } catch { return false }
    }

    @discardableResult
    static func bootout() -> Bool {
        guard isLoaded() else { return true }
        return runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
    }

    @discardableResult
    static func bootstrap() -> Bool {
        guard !isLoaded() else { return true }
        return runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    @discardableResult
    static func kickstart() -> Bool {
        return runLaunchctl(["kickstart", "-k", "gui/\(getuid())/\(label)"])
    }

    /// 常驻开关。关闭时当前实例（若是 job 进程）会被接管流程替换。
    @discardableResult
    static func toggle() -> Bool {
        if isInstalled() || isLoaded() {
            UserDefaults.standard.set(true, forKey: disabledKey)
            Store.shared.state.launchAtLogin = false
            Store.shared.save()
            guard uninstallViaDetach() else {
                UserDefaults.standard.set(false, forKey: disabledKey)
                Store.shared.state.launchAtLogin = true
                Store.shared.save()
                return true
            }
            return false
        }
        UserDefaults.standard.set(false, forKey: disabledKey)
        guard install() else {
            UserDefaults.standard.set(true, forKey: disabledKey)
            return false
        }
        return true
    }

    // MARK: helper 清理
    @discardableResult
    static func disableNow() -> Bool {
        try? FileManager.default.removeItem(at: plistURL)
        let stopped = bootout()
        return stopped && !isInstalled() && !isLoaded()
    }

    /// helper 进程不参与单实例接管，避免在 bootout 前杀死被 launchd 托管的实例。
    static func runDisableHelper() {
        guard disableNow() else {
            UserDefaults.standard.set(false, forKey: disabledKey)
            Store.shared.state.launchAtLogin = true
            Store.shared.save()
            _ = install()
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binaryPath)
        do { try p.run() } catch { NSLog("AR: 关闭常驻后重启失败：\(error)") }
    }

    // MARK: 单实例（新实例接管）

    static var pidFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AI到期提醒/instance.pid", isDirectory: false)
    }

    /// 终止旧实例并接管 pid 文件（新实例优先，收敛为单实例）
    static func acquireSingleInstance() {
        if let data = try? Data(contentsOf: pidFileURL),
           let str = String(data: data, encoding: .utf8),
           let old = Int(str.trimmingCharacters(in: .whitespacesAndNewlines)),
           old != ProcessInfo.processInfo.processIdentifier,
           kill(pid_t(old), 0) == 0 {
            NSLog("AR: 接管：终止旧实例 \(old)")
            kill(pid_t(old), SIGTERM)
            var waited = 0
            while waited < 20 && kill(pid_t(old), 0) == 0 {
                usleep(100_000)
                waited += 1
            }
            if kill(pid_t(old), 0) == 0 { kill(pid_t(old), SIGKILL) }
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        try? Data("\(pid)\n".utf8).write(to: pidFileURL)
    }

    static func releaseSingleInstance() {
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    // MARK: 底层

    @discardableResult
    static func runLaunchctl(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
