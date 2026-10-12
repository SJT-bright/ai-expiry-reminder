import Foundation
import AppKit

// MARK: - 常驻管理（LaunchAgent）
//
// 设计：
// - launchd 以 `--agent` 参数拉起应用（RunAtLoad 登录自启 + KeepAlive=true 无条件保活）
//   plist 显式带 AbandonProcessGroup=true：job 退出时 launchd 不再连坐清理其进程组，
//   否则我们派生的 --disable-resident-helper 会被一起收掉（表现为「取消勾选常驻后悬浮窗消失」）；
//   helper 自身启动即 setpgid(0,0) 脱组 + 父进程也尝试给子进程脱组，三重保险。
// - 手动打开的实例（无 --agent）在 install() 时 kickstart -k 把生命周期移交给 launchd，
//   launchd 的新实例通过「新实例接管」终止旧实例，最终收敛为 launchd 持有的单实例
// - 单实例 = pid 文件上的 flock(LOCK_EX|LOCK_NB)，fd 持有到进程退出。进程死亡（含 SIGKILL）
//   时内核自动放锁，所以既不需要清理残留锁，也绝不删除 pid 文件（换 inode 会让锁失效）。
//   杀旧实例前先用 bundleIdentifier / proc_pidpath 校验身份，确认不了就只退出、绝不 kill。
// - 被强杀/崩溃 → launchd 重启；节流由 plist 的 ThrottleInterval 决定（2 秒，非 1 秒）。
// - 菜单「退出」也会被立即重启（真常驻）
// - 彻底关闭：独立 helper 注销 job 并重开普通实例；关闭偏好在以后手动启动时继续生效
// - 线程约定：与 launchctl 的对话（print/bootstrap/kickstart，全部 waitUntilExit 阻塞）只在
//   launchctlQueue 上跑；isEnabledByUser / lastKnownLoaded 的读写与 UI 回灌只回主线程。
//   短命的 helper 进程例外（它跑完就 exit(0)，必须用同步版 installAndWait()）。

enum Resident {
    static let label = "com.sijunting.ai-expiry-reminder"
    /// bundle 标识（与 label 同值）：接管旧实例前用它校验「那个 pid 到底是不是本 App」
    static let bundleID = "com.sijunting.ai-expiry-reminder"
    private static let disabledKey = "residentDisabled"

    /// launchctl 交互专用串行队列：既不阻塞主线程，也避免并发的 bootstrap/kickstart 互相踩
    static let launchctlQueue = DispatchQueue(label: "com.sijunting.ai-expiry-reminder.launchctl")

    /// 最近一次后台探测到的 job 状态（nil = 还没探测过）。只在主线程读写。
    private(set) static var lastKnownLoaded: Bool?

    /// job 状态在后台刷新完毕（主线程广播），Settings/PanelUI 可据此回灌勾选态。
    /// 既有代码走 menuNeedsUpdate 轮询 isInstalled()，不监听也不会错。
    static let stateDidChange = Notification.Name("com.sijunting.ai-expiry-reminder.residentStateDidChange")

    static var isEnabledByUser: Bool {
        !UserDefaults.standard.bool(forKey: disabledKey)
    }

    static var isAgentSpawn: Bool {
        CommandLine.arguments.contains("--agent")
    }

    /// Application Support 根目录（不再 urls(for:).first! 强解；理论上不会失败，兜底更稳）
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// agent 日志目录：从可预测、可被抢注符号链接的 /tmp/aireminder.log 挪进来，
    /// 并且 stdout / stderr 分文件（原来两者写同一个 fd，交错后没法读）。
    static var logDirectory: URL {
        supportDirectory.appendingPathComponent("AI到期提醒/logs", isDirectory: true)
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

    /// 注意：这会 fork+waitUntilExit launchctl（几十~几百毫秒阻塞）。
    /// UI 路径（applicationDidFinishLaunching / 菜单 / 开关）请改读 lastKnownLoaded 或调
    /// refreshLoadedState()，别在主线程直接调它。
    static func isLoaded() -> Bool {
        runLaunchctl(["print", "gui/\(getuid())/\(label)"])
    }

    /// 后台刷新 job 状态：结果回主线程缓存，顺带广播给 UI（问题 6）。
    static func refreshLoadedState() {
        launchctlQueue.async {
            let loaded = isLoaded()
            DispatchQueue.main.async {
                Resident.lastKnownLoaded = loaded
                NotificationCenter.default.post(name: Resident.stateDidChange, object: nil)
            }
        }
    }

    // MARK: 安装 / 移除

    /// XML 文本转义：label / binaryPath / 日志路径都来自环境（用户名、安装路径可含 & < > ' "），
    /// 直接插进模板会写出无法解析甚至语义被截断的 plist（问题 7）。& 必须最先替换。
    static func xmlText(_ raw: String) -> String {
        var out = raw
        for (from, to) in [("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"), ("'", "&apos;")] {
            out = out.replacingOccurrences(of: from, with: to)
        }
        return out
    }

    /// 日志目录可用才写 StandardOut/ErrorPath；不可写时宁可不写（launchd 打不开重定向路径
    /// 会直接让 job 起不来），输出退回统一日志（log show --predicate 'process == "AIReminder"'）。
    private static func logPlistLines() -> String {
        guard FileManager.default.fileExists(atPath: logDirectory.path),
              FileManager.default.isWritableFile(atPath: logDirectory.path) else {
            return "    <!-- 日志目录 \(logDirectory.path) 不可写：stdout/stderr 走统一日志 -->"
        }
        let out = logDirectory.appendingPathComponent("agent.out.log")
        let err = logDirectory.appendingPathComponent("agent.err.log")
        return """
            <key>StandardOutPath</key><string>\(xmlText(out.path))</string>
            <key>StandardErrorPath</key><string>\(xmlText(err.path))</string>
        """
    }

    static func plistXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(xmlText(label))</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(xmlText(binaryPath))</string>
                <string>--agent</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>ProcessType</key><string>Background</string>
            <key>ThrottleInterval</key><integer>2</integer>
            <!-- job 退出时不要连坐清理进程组：关常驻用的是本 job 派生的 helper -->
            <key>AbandonProcessGroup</key><true/>
        \(logPlistLines())
        </dict>
        </plist>
        """
    }

    /// 确保常驻（问题 6）：
    /// - 写 plist 同步完成 —— isInstalled() 与菜单/设置勾选态必须立即可读；
    /// - launchctl 的 print/bootstrap/kickstart 丢到 launchctlQueue（它们内部 waitUntilExit，
    ///   原先在主线程 applicationDidFinishLaunching 里同步跑，冷启动最坏卡住数百毫秒）。
    /// 取舍：launchd 侧的「已生效」因此变成最终一致 —— 靠 stateDidChange + 下次菜单打开重读收敛，
    /// 换来主线程零阻塞。agent 实例自己就是 launchd 拉起来的，不问也知道 job 在跑。
    /// 调用约定：UI 侧（启动、菜单、开关）请在主线程调，本函数会写 lastKnownLoaded。
    @discardableResult
    static func install() -> Bool {
        ensureSupportDirectories()
        guard let unchanged = writePlist() else { return false }
        if isAgentSpawn {
            lastKnownLoaded = true   // 主线程调用；我就是 launchd 拉起的实例
            return true
        }
        launchctlQueue.async {
            if !isLoaded() {
                if !bootstrap() { NSLog("AR: bootstrap 失败，LaunchAgent 未生效（plist 已写好，重开一次常驻开关可重试）") }
            } else if !unchanged {
                // 定义有更新：重启 job（kickstart -k 终止旧 job 进程并立即拉起新的）
                if !kickstart() { NSLog("AR: kickstart 失败，运行中的仍是旧定义") }
            }
            let loaded = isLoaded()
            DispatchQueue.main.async {
                Resident.lastKnownLoaded = loaded
                NotificationCenter.default.post(name: Resident.stateDidChange, object: nil)
            }
        }
        return true
    }

    /// 同步版 install()：给「跑完就 exit(0)」的 helper 进程用（异步 guidance 在它退出前不会执行）。
    /// 别在 UI 进程的主线程里调。
    @discardableResult
    static func installAndWait() -> Bool {
        ensureSupportDirectories()
        guard let unchanged = writePlist() else { return false }
        if isAgentSpawn { return true }
        if !isLoaded() { return bootstrap() }
        if !unchanged { kickstart() }
        return true
    }

    /// plist 里的日志目录得先存在，launchd 只建文件不建父目录。
    private static func ensureSupportDirectories() {
        do {
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        } catch {
            NSLog("AR: 创建日志目录 \(logDirectory.path) 失败：\(error)；本次不写 StandardOut/ErrorPath")
        }
    }

    /// 原子写 plist（不再用 try? 吞错）。返回 nil = 写失败，返回 true = 定义与磁盘上的一致。
    private static func writePlist() -> Bool? {
        let url = plistURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            NSLog("AR: 创建 \(url.deletingLastPathComponent().path) 失败：\(error)")
            return nil
        }
        let xml = plistXML()
        let existing = try? String(contentsOf: url, encoding: .utf8)   // 文件不存在时 nil，属正常
        let unchanged = (existing == xml)
        do {
            try xml.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("AR: 写入 \(url.path) 失败：\(error)")
            return nil
        }
        return unchanged
    }

    /// launchd 会结束自己的 job 进程，因此由独立 helper 完成注销和普通实例重启（问题 4）。
    /// helper 必须脱离 job 的进程组，否则 bootout → job 退出 → launchd 清理进程组会把它连坐
    /// 杀掉，「重启普通实例」那步根本跑不到。三重保险：plist 的 AbandonProcessGroup=true、
    /// helper 自己 setpgid(0,0)、这里父进程也抢先给子进程脱组（缩小 spawn→exec 的竞态窗口）。
    @discardableResult
    static func uninstallViaDetach() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binaryPath)
        p.arguments = ["--disable-resident-helper"]
        do {
            try p.run()
        } catch {
            NSLog("AR: 派生 --disable-resident-helper 失败：\(error)")
            return false
        }
        if setpgid(p.processIdentifier, p.processIdentifier) != 0 {
            NSLog("AR: 给 helper(\(p.processIdentifier)) 脱组返回 errno=\(errno)（helper 会自行脱组，属预期竞态）")
        }
        return true
    }

    // 下面三个都会 fork launchctl 并 waitUntilExit（阻塞）：只允许在 launchctlQueue 上、
    // 或在没有 UI 的 helper 进程里调用。

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
    /// 判据用 isInstalled()（纯文件 stat，同步）+ lastKnownLoaded（后台探测的缓存值），
    /// 不再在主线程同步跑 `launchctl print`（问题 6）。
    /// 边界：plist 被外部删掉但 job 仍挂着、且启动时没开常驻 → 缓存为 nil 时本轮会走「开启」分支，
    /// 结果仍是把 plist 写好并把 job 收敛到常驻，方向正确；权威值请听 stateDidChange。
    @discardableResult
    static func toggle() -> Bool {
        if isInstalled() || (lastKnownLoaded ?? false) {
            UserDefaults.standard.set(true, forKey: disabledKey)
            guard uninstallViaDetach() else {
                UserDefaults.standard.set(false, forKey: disabledKey)
                return true
            }
            refreshLoadedState()
            return false
        }
        UserDefaults.standard.set(false, forKey: disabledKey)
        guard install() else {
            UserDefaults.standard.set(true, forKey: disabledKey)
            return false
        }
        refreshLoadedState()
        return true
    }

    // MARK: helper 清理（helper 进程里没有 UI，可以同步等 launchctl）

    @discardableResult
    static func disableNow() -> Bool {
        removePlistFile()
        let stopped = bootout()
        return stopped && !isInstalled() && !isLoaded()
    }

    private static func removePlistFile() {
        let url = plistURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            NSLog("AR: 删除 \(url.path) 失败：\(error)")
        }
    }

    /// helper 进程不参与单实例接管，避免在 bootout 前杀死被 launchd 托管的实例。
    static func runDisableHelper() {
        // 双保险（plist 已设 AbandonProcessGroup=true）：启动即自脱组，
        // 免得 bootout 之后 launchd 清理 job 进程组把「重启普通实例」这一步连坐带走。
        if setpgid(0, 0) != 0 { NSLog("AR: helper setpgid 失败 errno=\(errno)") }
        guard disableNow() else {
            UserDefaults.standard.set(false, forKey: disabledKey)
            _ = installAndWait()   // 同步版：本进程跑完就 exit(0)，异步 guidance 会来不及执行
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binaryPath)
        do { try p.run() } catch { NSLog("AR: 关闭常驻后重启失败：\(error)") }
    }

    // MARK: 单实例（pid 文件上的 flock 独占 + 身份校验接管）

    /// 持有到进程退出的 pid 文件 fd（<0 = 没持锁）。进程一死内核就放锁，
    /// 所以既不存在「残留锁需清理」，也绝不能 unlink pid 文件 —— 换 inode 会让锁互不相干。
    private(set) static var instanceLockFD: Int32 = -1

    static var pidFileURL: URL {
        supportDirectory.appendingPathComponent("AI到期提醒/instance.pid", isDirectory: false)
    }

    /// 抢单实例锁（问题 1/2/3）。原实现是「读 pid → kill(pid,0) → SIGTERM → SIGKILL → 写自己 pid」
    /// 的无锁 TOCTOU：两个进程同时读到同一个已死 pid，都跳过 kill、各自写文件，双面板永久并存。
    /// 现在：
    /// - 互斥交给 flock(LOCK_EX|LOCK_NB)，拿不到锁就绝不并行活着；
    /// - 锁被别人持有时，先确认那个 pid 是本 App（bundleIdentifier / 可执行路径）才接管；
    ///   确认不了就只退出，一个信号都不发（PID 复用杀无关进程 = 真实数据丢失）；
    /// - 旧实例是否真的走了，以「锁能不能拿到」为准，而不是 kill(pid,0)。
    /// 最坏情况：接管时同步等旧实例退出（SIGTERM 后最多 3s，SIGKILL 后最多 2s），
    /// 只发生在「同时开第二个副本 / 手动实例交接给 launchd 实例」这一瞬间，此时面板还没建。
    static func acquireSingleInstance() {
        let url = pidFileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            NSLog("AR: 创建 \(url.deletingLastPathComponent().path) 失败：\(error)")
        }
        // O_CLOEXEC：别让 fork/exec 出去的子进程（helper、重启的普通实例）继承同一个锁；
        // 权限取 0600 而非 0644 —— pid 只有本 uid 的诊断价值，不给同机其它用户读写。
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            // 连文件都打不开（磁盘/权限坏了）：此时无锁可用，继续启动比不启动有用，但要知道风险
            NSLog("AR: 打开 \(url.path) 失败 errno=\(errno)，本次不做单实例保护")
            return
        }
        if tryExclusiveLock(fd) {
            adoptLock(fd)
            return
        }

        let holder = recordedPID(url: url)
        guard let old = holder, isOwnProcess(pid: old) else {
            NSLog("AR: 单实例锁被占用，且无法确认持锁进程是本 App（pidfile 记录 \(String(describing: holder))）；"
                  + "为避免 PID 复用误杀无关进程，本实例直接退出")
            close(fd)
            exit(0)
        }

        NSLog("AR: 接管：终止旧实例 \(old)")
        if kill(pid_t(old), SIGTERM) != 0 { NSLog("AR: SIGTERM \(old) 失败 errno=\(errno)（可能已退出，继续等锁）") }
        if waitForLock(fd, within: 3_000_000) {
            adoptLock(fd)
            return
        }
        NSLog("AR: 旧实例 \(old) 未响应 SIGTERM，升级 SIGKILL")
        if kill(pid_t(old), SIGKILL) != 0 { NSLog("AR: SIGKILL \(old) 失败 errno=\(errno)") }
        if waitForLock(fd, within: 2_000_000) {
            adoptLock(fd)
            return
        }
        NSLog("AR: 旧实例 \(old) 未释放单实例锁，本实例退出（宁可少一个窗口也不双开）")
        close(fd)
        exit(0)
    }

    static func releaseSingleInstance() {
        // 原实现无条件 removeItem(pidFileURL)：接管者已写入自己的 pid 后，被杀方才跑到这里，
        // 会把存活实例的档案删掉 → 下次不再互斥 → 双开。现在只解自己的锁，且故意不删文件。
        guard instanceLockFD >= 0 else { return }
        if flock(instanceLockFD, LOCK_UN) != 0 { NSLog("AR: 解锁 pid 文件失败 errno=\(errno)") }
        close(instanceLockFD)
        instanceLockFD = -1
    }

    private static func tryExclusiveLock(_ fd: Int32) -> Bool {
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
        if errno != EWOULDBLOCK { NSLog("AR: flock 意外失败 errno=\(errno)") }
        return false
    }

    /// 轮询等锁：能加上锁 == 上一个持锁进程确实已退出（比 kill(pid,0) 可信）
    private static func waitForLock(_ fd: Int32, within microseconds: Int) -> Bool {
        let step = 50_000
        var waited = 0
        while waited < microseconds {
            usleep(UInt32(step))
            waited += step
            if tryExclusiveLock(fd) { return true }
        }
        return false
    }

    /// 持锁成功：把 pid 写进去当诊断信息（谁是持锁者一眼可见），fd 存进程级全局持有到退出。
    private static func adoptLock(_ fd: Int32) {
        let pid = ProcessInfo.processInfo.processIdentifier
        if ftruncate(fd, 0) != 0 { NSLog("AR: 清空 pid 文件失败 errno=\(errno)") }
        let bytes = Array("\(pid)\n".utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if written != bytes.count { NSLog("AR: 写 pid \(pid) 失败 written=\(written) errno=\(errno)（锁仍在，仅诊断信息缺失）") }
        instanceLockFD = fd
    }

    private static func recordedPID(url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int(trimmed), pid > 0 else { return nil }
        return pid
    }

    /// 身份校验：pid 可能已被复用。先问 LaunchServices（NSRunningApplication），
    /// 不是「已注册 App」（终端裸跑二进制等）时退回比对可执行路径；两条都对不上就返回 false。
    static func isOwnProcess(pid: Int) -> Bool {
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return false }
        if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
            return app.bundleIdentifier == bundleID
        }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        return String(cString: buffer) == binaryPath
    }

    // MARK: 底层

    /// fork /bin/launchctl 并 waitUntilExit（阻塞调用线程）—— 因此只在 launchctlQueue / helper 上跑。
    /// 失败原因不再只体现为 false：把参数和退出码写进统一日志（launchctl 的 stderr 仍丢弃，
    /// 避免 pipe 读法在 waitUntilExit 前死锁）。
    @discardableResult
    static func runLaunchctl(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            NSLog("AR: launchctl \(args.joined(separator: " ")) 启动失败：\(error)")
            return false
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            NSLog("AR: launchctl \(args.joined(separator: " ")) 退出码 \(p.terminationStatus)")
            return false
        }
        return true
    }
}
