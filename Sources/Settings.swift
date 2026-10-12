import AppKit

// MARK: - 悬停高亮表格：mouseMoved 跟踪光标所在行，回调给设置窗口做行高亮

final class HoverTableView: NSTableView {
    var onHoverRow: ((Int?) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if tracking == nil {
            let ta = NSTrackingArea(rect: .zero,
                                    options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                    owner: self, userInfo: nil)
            addTrackingArea(ta)
            tracking = ta
        }
    }

    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }

    override func mouseExited(with event: NSEvent) {
        onHoverRow?(nil)
    }

    private func updateHover(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let row = row(at: p)
        onHoverRow?(row >= 0 && row < numberOfRows ? row : nil)
    }
}

/// 行视图的呈现层轻微浮起，原始布局和点选区域保持稳定。
final class SettingsHoverRowView: NSTableRowView {
    private(set) var isHovered = false

    func setHovered(_ on: Bool, animated: Bool = true) {
        guard on != isHovered else { return }
        isHovered = on
        wantsLayer = true
        backgroundColor = .clear
        layer?.cornerRadius = 6
        Motion.float(self, on: on, lift: layer?.isGeometryFlipped == true ? -2 : 2,
                     animated: animated)
        Motion.highlight(self, on: on, color: NSColor(white: 1, alpha: 0.07),
                         animated: animated)
    }
}

// MARK: - 设置后台：所有订阅的管理窗口
// 悬浮窗只负责展示，添加 / 编辑 / 删除都在这里完成。

final class SettingsWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!
    private var table: NSTableView!
    private var items: [SubItem] = []
    private var launchCheckbox: NSButton!
    private var editBtn: NSButton!
    private var delBtn: NSButton!
    private var refreshBtn: NSButton!
    private let writeWarnLabel = NSTextField(labelWithString: "")
    private let horizonHint = NSTextField(labelWithString: "")
    private let displayHorizonField = NSTextField(string: "")
    private weak var panel: PanelController?
    private var reloadTimer: Timer?
    private var refreshPoll: Timer?
    /// weak：reloadData 之后旧 rowView 会被丢掉，强引用等于把脱离父视图的死行一直留在内存里
    private weak var hoveredRowView: SettingsHoverRowView?
    /// 当前悬停行号：表格刷新后按它把高亮补回去（rowView 是新建的，鼠标静置不会再发 mouseMoved）
    private var hoveredRow: Int?
    /// 上一次真正刷进表格的数据指纹：只有它变了才 reloadData
    private var lastFingerprint = ""
    private var closeObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    /// 点下开关时的意图：nil = 没有待收敛的操作。launchd 侧是最终一致的，
    /// 探测结果由 Resident.stateDidChange 回灌，届时才知道这次「开」是真开成了还是半截态。
    private var pendingResidentIntent: Bool?
    private var residentObserver: NSObjectProtocol?
    /// 程序化改窗口位置（恢复/居中）期间置 true：didMove 通知会跟着发，
    /// 不挡住的话「已离屏的旧坐标」会被重新写回 UserDefaults，回位逻辑永远修不好
    private var applyingOrigin = false
    /// 警示行来源分类：删除失败与写盘失败共用同一行 label，互相不得越界清除
    /// （用 quiet 不用 none，避开和 Optional.none 的写法撞车）
    private enum WarnKind { case quiet, write, delete, resident, other }
    private var warnKind: WarnKind = .quiet

    /// 写盘失败警示行的固定文案
    private static let writeWarnText = "⚠ 设置保存失败，更改未写入磁盘"
    /// 设置窗位置持久化 key（与 PanelUI 的 panelOrigin 同族做法：UserDefaults 存 [Double]）
    private static let originKey = "settingsWindowOrigin"

    init(panel: PanelController) {
        self.panel = panel
        super.init()
        buildWindow()
        reloadFromStore()
        startTicker()
        // 设置写盘结果（Store 保证主线程回调）；成功清除旧失败提示
        Store.shared.onSettingsWriteResult = { [weak self] ok in
            self?.updateWriteWarnLabel(ok: ok)
        }
        // 常驻的 launchd 状态是后台探测的（isLoaded() 会 fork+wait launchctl，主线程不能等）；
        // 结果回来只在这里落勾选框，半截态只在用户刚点过「开」时才上报。
        residentObserver = NotificationCenter.default.addObserver(
            forName: Resident.stateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.syncResidentState()
        }
    }

    /// 探测回来：按缓存落勾选框；只有带着「开」的意图时才判定半截态并明示。
    private func syncResidentState() {
        launchCheckbox.state = residentIsOn ? .on : .off
        guard pendingResidentIntent == true else { return }
        pendingResidentIntent = nil
        if residentIsOn {
            clearWarn(ifKind: .resident)
        } else if Resident.isInstalled() {
            warnHalfInstalled()                       // plist 落了但 job 没加载：必须摆到眼前
        }
    }

    deinit {
        // 1 秒计时器与通知观察者必须在这里摘净：窗口藏起来后它们不该继续 sortedRows()
        reloadTimer?.invalidate()
        reloadTimer = nil
        refreshPoll?.invalidate()
        refreshPoll = nil
        if let o = closeObserver { NotificationCenter.default.removeObserver(o) }
        if let o = moveObserver { NotificationCenter.default.removeObserver(o) }
        if let o = residentObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: 每秒刷新计时器（窗口不可见就停手，别和面板 tick 叠着空转）

    private func startTicker() {
        guard reloadTimer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.softReload() }
        RunLoop.main.add(t, forMode: .common)
        reloadTimer = t
    }

    private func stopTicker() {
        reloadTimer?.invalidate()
        reloadTimer = nil
        lastFingerprint = ""      // 下次打开强制整表刷新：隐藏期间的变化要看得见
        highlightHoverRow(nil, animated: false)
    }

    /// 表格行悬停高亮（当前悬停行背景微亮，移出还原）
    private func highlightHoverRow(_ row: Int?, animated: Bool = true) {
        hoveredRow = row
        let next = row.flatMap { index -> SettingsHoverRowView? in
            guard index >= 0, index < table.numberOfRows else { return nil }
            return table.rowView(atRow: index, makeIfNecessary: false) as? SettingsHoverRowView
        }
        guard next !== hoveredRowView else { return }
        hoveredRowView?.setHovered(false, animated: animated)
        hoveredRowView = next
        next?.setHovered(true, animated: animated)
    }

    /// 表格 reloadData 之后补回悬停高亮；行视图在布局结束后才建得出来，所以排到下一轮主循环
    private func restoreHoverHighlight() {
        guard let row = hoveredRow else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.hoveredRow == row else { return }
            self.highlightHoverRow(row, animated: false)
        }
    }

    /// 警示/提示行淡入淡出的过期令牌：快速显隐交替时，过期的淡出完成回调不得把
    /// 已经重新显示的行藏掉
    private var warnFadeToken = 0
    private var hintFadeToken = 0

    /// 警示行统一出口：文案 + 来源分类（首次出现淡入，不是突然冒出来）
    private func showWarn(_ text: String, kind: WarnKind) {
        warnKind = kind
        writeWarnLabel.stringValue = text
        guard writeWarnLabel.isHidden else { return }
        warnFadeToken += 1
        writeWarnLabel.isHidden = false
        Motion.reveal(writeWarnLabel, duration: 0.2)
    }

    /// 收起警示行；给了 kind 就只收自己那一类（别把写盘失败的提示顺手抹掉）
    private func clearWarn(ifKind kind: WarnKind? = nil) {
        if let kind, warnKind != kind { return }
        warnKind = .quiet
        guard !writeWarnLabel.isHidden else { return }
        warnFadeToken += 1
        let token = warnFadeToken
        Motion.fadeOut(writeWarnLabel, duration: 0.18) { [weak self] in
            guard let self, token == self.warnFadeToken else { return }
            self.writeWarnLabel.isHidden = true
            self.writeWarnLabel.alphaValue = 1
        }
    }

    /// 依据最近一次写盘结果更新警示行（主线程）
    private func updateWriteWarnLabel(ok: Bool) {
        if ok { clearWarn(ifKind: .write) } else { showWarn(Self.writeWarnText, kind: .write) }
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 352),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 300)
        window.acceptsMouseMovedEvents = true
        Glass.glassWindow(window)

        // ---- 条目表格（背景透明，透出玻璃材质）----
        let hoverTable = HoverTableView()
        hoverTable.onHoverRow = { [weak self] row in self?.highlightHoverRow(row) }
        table = hoverTable
        table.style = .inset
        table.rowHeight = 24
        // inset 样式默认每列多留20pt；显式收紧，末列“来源”才不会被视口裁掉。
        table.intercellSpacing = NSSize(width: 3, height: 2)
        table.headerView = NSTableHeaderView()
        table.focusRingType = .none
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.backgroundColor = .clear
        table.setAccessibilityIdentifier("settingsRecordsTable")
        table.gridStyleMask = []
        // 列宽总和 568 < 视口 586（窗宽 720 − 按钮列 104 − 左右边距 16−2），
        // 任何缩放/滚动条情况下都不会裁切。加列或改宽度时同步改这里的数字。
        for (id, title, width) in [("name", "名称", 168.0),
                                   ("vendor", "供应商", 84.0),
                                   ("expires", "到期时间", 148.0),
                                   ("remain", "剩余", 80.0),
                                   ("source", "来源", 88.0)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            col.minWidth = 36
            col.resizingMask = [.userResizingMask]
            table.addTableColumn(col)
        }
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(editSelected)
        table.allowsColumnReordering = false

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay   // 悬浮滚动条不占宽度，避免最后一列被挤出视口
        scroll.drawsBackground = false
        scroll.focusRingType = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scrollRef = scroll

        // ---- 操作按钮（无边框胶囊芯片：圆角由 HoverEffectButton.layout 按高度一半裁，不手写 cornerRadius）----
        func styleChip(_ b: HoverEffectButton) {
            b.isBordered = false
            b.wantsLayer = true
            b.font = .systemFont(ofSize: 12, weight: .medium)
            b.contentTintColor = NSColor(white: 1, alpha: 0.92)
            b.restFill = NSColor(white: 1, alpha: 0.10)
            b.layer?.borderWidth = 0.5
            b.layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor
            b.contentPadding = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        }
        let addBtn = HoverEffectButton(title: "添加", target: self, action: #selector(addClicked))
        let editBtn = HoverEffectButton(title: "编辑", target: self, action: #selector(editSelected))
        let delBtn = HoverEffectButton(title: "删除", target: self, action: #selector(deleteSelected))
        let refreshBtn = HoverEffectButton(title: "刷新官方", target: self, action: #selector(refreshClicked))
        let cleanBtn = HoverEffectButton(title: "清理过期", target: self, action: #selector(cleanExpired))
        [addBtn, editBtn, delBtn, refreshBtn, cleanBtn].forEach(styleChip)
        for (button, id) in [(addBtn, "settingsAdd"), (editBtn, "settingsEdit"),
                             (delBtn, "settingsDelete"), (refreshBtn, "settingsRefresh"),
                             (cleanBtn, "settingsClean")] {
            button.setAccessibilityIdentifier(id)
        }
        self.editBtn = editBtn
        self.delBtn = delBtn
        self.refreshBtn = refreshBtn
        editBtn.isEnabled = false
        delBtn.isEnabled = false
        let btnCol = NSStackView(views: [addBtn, editBtn, delBtn, NSView(), refreshBtn, cleanBtn])
        btnCol.orientation = .vertical
        btnCol.spacing = 8
        btnCol.translatesAutoresizingMaskIntoConstraints = false

        // ---- 底部功能只占一行；说明和错误在必要时另起一行 ----
        launchCheckbox = NSButton(checkboxWithTitle: "常驻（开机自启+崩溃自动拉起）", target: self, action: #selector(toggleLaunch))
        launchCheckbox.font = .systemFont(ofSize: 10.5)
        launchCheckbox.state = residentIsOn ? .on : .off
        launchCheckbox.setAccessibilityIdentifier("settingsResident")
        let folderBtn = HoverEffectButton(title: "打开数据文件夹", target: self, action: #selector(openFolder))
        styleChip(folderBtn)
        folderBtn.controlSize = .small
        folderBtn.setAccessibilityIdentifier("settingsDataFolder")

        let horizonLabel = NSTextField(labelWithString: "即将到期范围")
        horizonLabel.font = .systemFont(ofSize: 12)
        let horizonUnit = NSTextField(labelWithString: "天内")
        horizonUnit.font = .systemFont(ofSize: 12)
        displayHorizonField.identifier = NSUserInterfaceItemIdentifier("displayHorizonField")
        displayHorizonField.stringValue = String(Store.shared.displayHorizonDays)
        displayHorizonField.font = .systemFont(ofSize: 12)
        displayHorizonField.alignment = .center
        displayHorizonField.target = self
        displayHorizonField.action = #selector(horizonEdited)
        (displayHorizonField.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        displayHorizonField.translatesAutoresizingMaskIntoConstraints = false
        displayHorizonField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let horizonRow = NSStackView(views: [horizonLabel, displayHorizonField, horizonUnit])
        horizonRow.orientation = .horizontal
        horizonRow.alignment = .centerY
        horizonRow.spacing = 6

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let settingsRow = NSStackView(views: [launchCheckbox, folderBtn, spacer, horizonRow])
        settingsRow.orientation = .horizontal
        settingsRow.alignment = .centerY
        settingsRow.spacing = 12
        settingsRow.setAccessibilityIdentifier("settingsFooterRow")

        // 展示窗口以外的周次不进表格，但还在库里；有这种条目时给一行安静说明，避免误以为被删了
        horizonHint.font = .systemFont(ofSize: 10.5)
        horizonHint.textColor = .secondaryLabelColor
        horizonHint.isHidden = true

        // 设置写盘失败警示行（写盘成功后自动清除；仅在主线程更新）
        writeWarnLabel.stringValue = Self.writeWarnText
        writeWarnLabel.font = .systemFont(ofSize: 10.5)
        writeWarnLabel.textColor = .systemRed
        writeWarnLabel.isHidden = true

        let bottom = NSStackView(views: [settingsRow, horizonHint, writeWarnLabel])
        bottom.orientation = .vertical
        bottom.alignment = .leading
        bottom.spacing = 6
        bottom.translatesAutoresizingMaskIntoConstraints = false

        // ---- 玻璃底板 + 顶部标题 ----
        // 满幅贴窗：圆角由标题窗自己裁，这里给 0；给正值反而会从窗口圆角里缩进一圈。
        // 底板吃 bodyTint（行片不吃），白字在浅色壁纸上才稳得住。
        let glass = Glass.make(cornerRadius: 0, tint: Glass.bodyTint)
        glass.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "⏳ AI到期提醒 · 设置后台")
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(glass)
        container.addSubview(scroll)
        container.addSubview(btnCol)
        container.addSubview(bottom)
        container.addSubview(titleLabel)
        window.contentView = container

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 84),

            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 32),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: btnCol.leadingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -10),

            btnCol.topAnchor.constraint(equalTo: container.topAnchor, constant: 32),
            btnCol.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            btnCol.widthAnchor.constraint(equalToConstant: 104),

            bottom.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            bottom.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            bottom.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),

            settingsRow.widthAnchor.constraint(equalTo: bottom.widthAnchor),
        ])

        // 关掉即停表：isReleasedWhenClosed=false，close 只是把窗藏起来，计时器不该继续跑
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in self?.stopTicker() }
        // 用户拖过的位置要留住（只在窗口自己移动时记账，程序化 center/恢复由 applyingOrigin 挡掉）
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main
        ) { [weak self] note in
            guard let self, !self.applyingOrigin,
                  (note.object as? NSWindow) === (self.window as NSWindow?) else { return }
            self.saveWindowOrigin()
        }
    }

    // MARK: 窗口位置（第 6 条：别每次打开都 center() 把用户拖的位置丢掉）

    /// 自启真值：plist 落盘 **且** launchd 已加载。
    /// 只看文件存在会把「写成功但 bootstrap 失败」的半截状态显示成「开」，
    /// 再点一次走的就是卸载分支 —— UI 与真实状态自相矛盾。
    /// loaded 一律读 Resident 的缓存值：`isLoaded()` 会 fork+waitUntilExit launchctl
    /// （几十~几百毫秒阻塞），UI 路径绝不能直接调它；权威变化由 stateDidChange 回灌。
    private var residentIsOn: Bool {
        Resident.isInstalled() && (Resident.lastKnownLoaded ?? false)
    }
    /// 与 Resident.toggle() 内部分支同一判据：它按「plist 在不在 / job 加载没加载」决定这一下是装还是卸
    private var residentWillToggleOff: Bool {
        Resident.isInstalled() || (Resident.lastKnownLoaded ?? false)
    }

    private func saveWindowOrigin() {
        // NSValue 不是合法 plist 类型，和 panelOrigin 一样存 [Double]
        let o = window.frame.origin
        UserDefaults.standard.set([Double(o.x), Double(o.y)], forKey: Self.originKey)
    }

    /// 有记录且仍落在现存某块屏幕上 → 用之；否则丢弃旧坐标并居中
    private func restoreWindowOrigin() {
        applyingOrigin = true
        defer { applyingOrigin = false }
        guard let xy = UserDefaults.standard.array(forKey: Self.originKey) as? [Double], xy.count == 2 else {
            window.center()
            return
        }
        let p = NSPoint(x: xy[0], y: xy[1])
        guard let scr = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -8, dy: -8).contains(p) }) else {
            UserDefaults.standard.removeObject(forKey: Self.originKey)   // 显示器拔了/换排列
            window.center()
            return
        }
        let f = window.frame
        // 夹回屏内：老坐标可能只露出左上角，够得着但看不见
        let x = min(max(p.x, scr.frame.minX), max(scr.frame.minX, scr.frame.maxX - f.width))
        let y = min(max(p.y, scr.frame.minY), max(scr.frame.minY, scr.frame.maxY - f.height))
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func showWindow(_ sender: Any?) {
        restoreWindowOrigin()
        window.makeKeyAndOrderFront(sender)
        Motion.present(window)   // 整体淡入 + 内容轻微上浮归位，不再硬切出现
        startTicker()
        // 常驻态可能被面板右键菜单（或外部 launchctl）改过，buildWindow 时读的那一次早就失效
        launchCheckbox.state = residentIsOn ? .on : .off
        // 缓存可能来自上一次探测：这里发起一次后台重取，回来由 syncResidentState 落勾
        Resident.refreshLoadedState()
        // 打开即重取一次数据：窗口隐藏期间计时器是停着的，行序停在上次关闭时
        reloadFromStore()
        // 打开时按最近一次写盘结果同步警示行
        if let ok = Store.shared.lastSettingsWriteOK {
            updateWriteWarnLabel(ok: ok)
        }
    }

    var windowRef: NSWindow? { window }

    /// 自测用：输出真实几何信息
    func debugPrintGeometry() {
        let cols = table.tableColumns.map { "\($0.identifier.rawValue)=\(Int($0.width))" }.joined(separator: " ")
        print("GEOM scroll=\(scrollRef?.bounds.size ?? .zero) table=\(table.frame) cols[\(cols)]")
    }

    private weak var scrollRef: NSScrollView?

    // MARK: 外部入口

    /// 打开设置后台并直接弹出「添加」表单
    func openForAdd() {
        showWindow(nil)
        addClicked()
    }

    /// 打开设置后台并编辑指定条目
    func openForEdit(_ item: SubItem) {
        showWindow(nil)
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            table.scrollRowToVisible(idx)
        }
        editSelected()
    }

    // MARK: 数据

    /// 与面板同一展示窗口：超过 displayHorizonDays 不进表格，远周次留在数据库里，不删除。
    /// 窗口内再按 displaySorted 排：归档/长期过期沉到底，避免纯到期升序把临近项挤下去。
    private func sortedRows() -> [SubItem] {
        let now = Date()
        let all = panel?.snapshotItems() ?? []
        return SubItem.displaySorted(all.filter { $0.isWithinDisplayHorizon(now: now) }, now: now)
    }

    /// 远周次不在表里，但库里还在。为 0 就藏起来；跨过天数边界时由每秒刷新改文案。
    /// 显隐走淡入淡出并带令牌防过期回调；文案变化即时生效（每秒刷新路径不做动画重播）。
    private func updateHorizonHint() {
        let now = Date()
        let hidden = (panel?.snapshotItems() ?? []).filter { !$0.isWithinDisplayHorizon(now: now) }.count
        if hidden == 0 {
            guard !horizonHint.isHidden else { return }
            hintFadeToken += 1
            let token = hintFadeToken
            Motion.fadeOut(horizonHint, duration: 0.2) { [weak self] in
                guard let self, token == self.hintFadeToken else { return }
                self.horizonHint.isHidden = true
                self.horizonHint.alphaValue = 1
            }
        } else {
            hintFadeToken += 1
            let days = Store.shared.displayHorizonDays
            horizonHint.stringValue = "另有 \(hidden) 条距到期超过 \(days) 天，已在数据库里，进入 \(days) 天内再显示"
            let wasHidden = horizonHint.isHidden
            horizonHint.isHidden = false
            if wasHidden { Motion.reveal(horizonHint, duration: 0.2) }
        }
    }

    /// 空白或非整数不写 Store，输入框收回当前天数（不出声）。合法值夹紧后立刻重排设置表和面板，并给一次轻点反馈。
    @objc private func horizonEdited() {
        let raw = displayHorizonField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let days = Int(raw) else {
            displayHorizonField.stringValue = String(Store.shared.displayHorizonDays)
            return
        }
        Store.shared.setDisplayHorizonDays(days)
        Motion.playTap()
        displayHorizonField.stringValue = String(Store.shared.displayHorizonDays)
        reloadFromStore()
        panel?.tick()
    }

    private func reloadFromStore() {
        items = sortedRows()
        lastFingerprint = fingerprint(of: items)
        table.reloadData()
        restoreHoverHighlight()
        updateButtonStates()
        updateHorizonHint()
    }

    /// 数据指纹：只含表格里真会显示出来的字段。
    /// 每秒无条件 reloadData 会销毁全部 rowView，鼠标静置时悬停高亮每秒被抹一次
    /// （要再动一次鼠标才回来）；指纹没变就根本不碰表格。
    private func fingerprint(of rows: [SubItem]) -> String {
        var s = ""
        s.reserveCapacity(rows.count * 64)
        for r in rows {
            s += "\(r.id)|\(Fmt.absTime(r.expiresAt))|\(Fmt.countdownShort(until: r.expiresAt))|"
            s += "\(r.isAuto ? "官方" : "手动")\(r.isArchived ? "已归档" : "")\n"
        }
        return s
    }

    /// 每秒轻量刷新：更新倒计时列 + 同步官方数据变化
    private func softReload() {
        // 窗口没显示（含最小化）时一行都不排：面板自己也在 tick，两边叠着空转纯属浪费
        guard window.isVisible, table.window != nil else {
            updateHorizonHint()
            return
        }
        // 重排后行号会变，选中项必须按 id 复位：按行号复位会把编辑/删除按钮指到别的条目上
        let sel = table.selectedRow
        let selID = (sel >= 0 && sel < items.count) ? items[sel].id : nil
        items = sortedRows()
        let fp = fingerprint(of: items)
        guard fp != lastFingerprint else {
            updateButtonStates()
            updateHorizonHint()
            return
        }
        lastFingerprint = fp
        table.reloadData()
        if let selID, let row = items.firstIndex(where: { $0.id == selID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        restoreHoverHighlight()
        updateButtonStates()
        updateHorizonHint()
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtonStates()
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SettingsHoverRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let column, let value = self.tableView(tableView, objectValueFor: column, row: row) else { return nil }
        let id = column.identifier
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.textField?.stringValue = String(describing: value)
        return cell
    }

    /// 编辑/删除按钮随选中状态启用：未选中置灰，官方条目不可删
    private func updateButtonStates() {
        let row = table.selectedRow
        let item = (row >= 0 && row < items.count) ? items[row] : nil
        editBtn?.isEnabled = item != nil
        delBtn?.isEnabled = item?.isAuto == false
    }

    func tableView(_ tableView: NSTableView, objectValueFor column: NSTableColumn?, row: Int) -> Any? {
        guard row >= 0, row < items.count, let col = column?.identifier.rawValue else { return nil }
        let item = items[row]
        switch col {
        case "name": return item.name
        case "vendor": return item.vendor
        case "expires": return Fmt.absTime(item.expiresAt)
        case "remain": return Fmt.countdownShort(until: item.expiresAt)
        case "source":
            // README 承诺设置后台「含已归档项」：光在表里根本看不出哪条是归档的，来源列一并标出来
            return item.isAuto ? "官方" : (item.isArchived ? "手动 · 已归档" : "手动")
        default: return nil
        }
    }

    // MARK: 动作

    @objc private func addClicked() {
        panel?.openEditor(.manualDefault(), isNew: true, on: window,
                          saved: { [weak self] in self?.reloadFromStore() },
                          deleted: { [weak self] in self?.reloadFromStore() })
    }

    @objc private func editSelected() {
        let row = table.selectedRow
        guard row >= 0, row < items.count else {
            let alert = NSAlert()
            alert.messageText = "请先在列表中选择一条记录"
            alert.informativeText = "单击选中后即可编辑（双击行也可直接编辑）。"
            FloatingWindowPolicy.runAlert(alert)
            return
        }
        panel?.openEditor(items[row], isNew: false, on: window,
                          saved: { [weak self] in self?.reloadFromStore() },
                          deleted: { [weak self] in self?.reloadFromStore() })
    }

    @objc private func deleteSelected() {
        let row = table.selectedRow
        guard row >= 0, row < items.count else { return }
        let item = items[row]
        if item.isAuto {
            let alert = NSAlert()
            alert.messageText = "官方数据条目无法删除"
            alert.informativeText = "「\(item.name)」来自官方本地数据自动同步，刷新后会重新出现。"
            FloatingWindowPolicy.runAlert(alert)
            return
        }
        // 按周划分生成的组：询问删除整组还是仅此条（回车默认 = 取消，防误删）
        if let gid = item.groupID {
            // 表格可能只剩 1 条可见周次；整组条数要数库里的（含 40 天外、尚未展示的）
            let groupCount = Store.shared.manualItems.filter { $0.groupID == gid }.count
            if groupCount > 1 {
                let alert = NSAlert()
                alert.messageText = "「\(item.name)」属于按周划分组（共 \(groupCount) 条）"
                alert.informativeText = "要删除整组，还是仅删除这一条？删除后不可恢复。"
                let allBtn = alert.addButton(withTitle: "删除整组(\(groupCount))")
                alert.addButton(withTitle: "仅此条")
                alert.addButton(withTitle: "取消")
                allBtn.hasDestructiveAction = true
                allBtn.contentTintColor = .systemRed
                alert.buttons.last?.keyEquivalent = "\r"
                NSApp.activate(ignoringOtherApps: true)
                // 显式 switch：未知/异常返回值一律视为取消，不落到后续确认框
                switch FloatingWindowPolicy.runAlert(alert) {
                case .alertFirstButtonReturn:
                    Store.shared.deleteGroup(gid)
                    reloadFromStore()
                    reportDeleteFailure(Store.shared.manualItems.contains { $0.groupID == gid },
                                        "「\(item.name)」所在分组")
                    return
                case .alertSecondButtonReturn:
                    // 组对话框本身就是确认，「仅此条」为显式选择，直接删（与悬浮窗行为一致）
                    Store.shared.deleteManualWithDerived(item.id)
                    reloadFromStore()
                    reportDeleteFailure(Store.shared.manualItems.contains { $0.id == item.id },
                                        "「\(item.name)」")
                    return
                default:
                    return
                }
            }
        }
        guard DeleteConfirm.run(item, hint: "手动录入的信息删除后不可恢复，需要重新录入") else { return }
        Store.shared.deleteManualWithDerived(item.id)
        reloadFromStore()
        reportDeleteFailure(Store.shared.manualItems.contains { $0.id == item.id }, "「\(item.name)」")
    }

    /// 删除类操作的失败自证：Store 的 deleteManualWithDerived / deleteManualsWithDerived 返回 Void、
    /// deleteGroup 的 Int 在这里也没人接（DB 只读时表格重载后条目照样在），
    /// 唯一能在本文件内拿到的真相就是「manualItems 里还剩没剩」。
    /// 失败必须显式提示，否则用户反复点「删除」却一点反馈都没有。
    private func reportDeleteFailure(_ stillThere: Bool, _ subject: String) {
        if stillThere {
            showWarn("⚠ 删除失败：\(subject)仍在列表里（数据库只读或磁盘已满）", kind: .delete)
            NSLog("AR: 设置后台删除未生效：\(subject)")
        } else {
            clearWarn(ifKind: .delete)
        }
    }

    @objc private func refreshClicked() {
        guard refreshBtn.isEnabled else { return }
        refreshBtn.isEnabled = false
        refreshBtn.title = "刷新中…"
        panel?.refreshData()
        watchRefreshFinish()
    }

    /// 以「面板自己的 ⟳ 恢复可用」为刷新完成判据。
    /// 写死 +1.2s 会在读者还没跑完时就报「✓ 已刷新」，用户以为拿到了新数据其实没有。
    /// PanelController 的 refreshing 是 private 且没有完成回调，这是设置侧唯一能观察到的真实信号。
    private func watchRefreshFinish() {
        refreshPoll?.invalidate()
        let started = Date()
        var sawRunning = false
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let running = self.panel.map { $0.debugRefreshIndicatorOn } ?? false
            if running { sawRunning = true }
            // 没观察到过「刷新中」时至少等半秒再收，避免面板尚未置位就误判成已完成
            if !running, sawRunning || Date().timeIntervalSince(started) > 0.5 {
                t.invalidate()
                self.refreshPoll = nil
                self.reloadFromStore()
                self.refreshBtn.title = "✓ 已刷新"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                    self?.refreshBtn.title = "刷新官方"
                    self?.refreshBtn.isEnabled = true
                }
                return
            }
            if Date().timeIntervalSince(started) > 60 {   // 读者遍历磁盘可能很久：真超时才放手，但不能永久按死
                t.invalidate()
                self.refreshPoll = nil
                self.refreshBtn.title = "刷新官方"
                self.refreshBtn.isEnabled = true
                NSLog("AR: 设置后台等待刷新完成超时，按未完成处理")
            }
        }
        refreshPoll = timer
        RunLoop.main.add(timer, forMode: .common)   // 模态弹窗/滚动期间也要继续轮询
    }

    @objc private func toggleLaunch() {
        // 判据与 Resident.toggle() 内部一致（isInstalled + 缓存的 loaded），全程不在主线程跑 launchctl
        let intendedInstall = !residentWillToggleOff
        let nowOn = Resident.toggle()
        if !intendedInstall {
            // 这一下是「关」：注销由独立 helper 异步完成，本地立刻落「关」。
            // 此刻去读真实态会读到还没 bootout 的旧 job，勾会被回弹成「开」（下次打开才对）
            pendingResidentIntent = nil
            launchCheckbox.state = .off
            clearWarn(ifKind: .resident)
            return
        }
        guard nowOn else {
            // plist 都没写成，不必等探测
            pendingResidentIntent = nil
            launchCheckbox.state = .off
            showWarn("⚠ 开机自启开启失败：启动项未能写入磁盘", kind: .resident)
            return
        }
        // 「开」已落盘，job 是否真被 launchd 加载由 toggle() 触发的后台探测决定；
        // 先按当前缓存落一眼，半截态等 stateDidChange 回来再由 syncResidentState 明示。
        pendingResidentIntent = true
        launchCheckbox.state = residentIsOn ? .on : .off
    }

    /// plist 已落盘但 launchd 未加载 = 「半个开」。勾选框只能显示关，
    /// 这个矛盾必须摆到用户眼前，否则下一次点击走的是卸载分支。
    private func warnHalfInstalled() {
        let alert = NSAlert()
        alert.messageText = "开机自启未生效"
        alert.informativeText = "启动项已写入 \(Resident.plistURL.path)，但 launchd 未加载该作业，"
            + "所以勾选框显示为「关」。\n可在终端手动加载：\n"
            + "launchctl bootstrap gui/$UID \(Resident.plistURL.path)"
        FloatingWindowPolicy.runAlert(alert)
        showWarn("⚠ 开机自启未生效：启动项已写入，但 launchd 未加载", kind: .resident)
    }

    /// 删除过期超过归档阈值（3 天，与自动归档同口径）的手动条目：
    /// 官方数据、已归档条目、仍在滚动的额度窗口都不在名单内
    @objc private func cleanExpired() {
        let expired = Store.shared.expiredManualItems()
        guard !expired.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "没有需要清理的条目"
            alert.informativeText = "没有过期超过 \(Int(Store.archiveAfterDays)) 天的手动条目需要清理。"
            FloatingWindowPolicy.runAlert(alert)
            return
        }
        let alert = NSAlert()
        alert.messageText = "清理 \(expired.count) 条已过期条目？"
        alert.informativeText = "将删除过期超过 \(Int(Store.archiveAfterDays)) 天的手动记录（已归档条目与仍在滚动的额度窗口不在此列）：\n"
            + expired.prefix(5).map { "· \($0.name)" }.joined(separator: "\n")
            + (expired.count > 5 ? "\n…" : "")
        alert.addButton(withTitle: "取消")           // 回车默认 = 取消，防误清
        let go = alert.addButton(withTitle: "清理")
        go.hasDestructiveAction = true
        go.contentTintColor = .systemRed
        NSApp.activate(ignoringOtherApps: true)
        guard FloatingWindowPolicy.runAlert(alert) == .alertSecondButtonReturn else { return }
        let ids = Set(expired.map { $0.id })
        Store.shared.deleteManualsWithDerived(expired.map { $0.id })
        reloadFromStore()
        let leftover = Store.shared.manualItems.filter { ids.contains($0.id) }.count
        if leftover > 0 {
            showWarn("⚠ 清理失败：\(leftover)/\(expired.count) 条仍在列表里（数据库只读或磁盘已满）",
                     kind: .delete)
            NSLog("AR: 设置后台清理过期未生效 \(leftover)/\(expired.count)")
        } else {
            clearWarn(ifKind: .delete)
        }
    }

    /// 打开数据文件夹：一律走 Store.dir —— 它认 AR_DATA_DIR 注入，才是数据真身目录；
    /// 自己 `urls(for:).first!` 既强解又可能在测试环境里指向别的盘子。目录不存在就明说，
    /// 别把 Finder 的报错窗当反馈。
    @objc private func openFolder() {
        let dir = Store.shared.dir
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            showWarn("⚠ 数据目录不存在：\(dir.path)", kind: .other)
            NSLog("AR: 打开数据文件夹失败，目录不存在：\(dir.path)")
            return
        }
        clearWarn(ifKind: .other)
        NSWorkspace.shared.open(dir)
    }
}
