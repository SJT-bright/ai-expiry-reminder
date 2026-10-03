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
    private weak var panel: PanelController?
    private var reloadTimer: Timer?
    private var refreshPoll: Timer?
    private var hoveredRowView: NSTableRowView?

    init(panel: PanelController) {
        self.panel = panel
        super.init()
        buildWindow()
        reloadFromStore()
        reloadTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.softReload()
        }
        if let t = reloadTimer { RunLoop.main.add(t, forMode: .common) }
        // 设置写盘结果（Store 保证主线程回调）；成功清除旧失败提示
        Store.shared.onSettingsWriteResult = { [weak self] ok in
            self?.updateWriteWarnLabel(ok: ok)
        }
    }

    /// 表格行悬停高亮（当前悬停行背景微亮，移出还原）
    private func highlightHoverRow(_ row: Int?) {
        if let old = hoveredRowView { old.backgroundColor = .clear }
        hoveredRowView = nil
        guard let row, row >= 0, row < table.numberOfRows else { return }
        if let rv = table.rowView(atRow: row, makeIfNecessary: false) {
            rv.backgroundColor = NSColor(white: 1, alpha: 0.05)
            hoveredRowView = rv
        }
    }

    /// 依据最近一次写盘结果更新警示行（主线程）
    private func updateWriteWarnLabel(ok: Bool) {
        writeWarnLabel.isHidden = ok
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 384),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        Glass.glassWindow(window)

        // ---- 条目表格（背景透明，透出玻璃材质）----
        let hoverTable = HoverTableView()
        hoverTable.onHoverRow = { [weak self] row in self?.highlightHoverRow(row) }
        table = hoverTable
        table.style = .inset
        table.rowHeight = 24
        table.headerView = NSTableHeaderView()
        table.focusRingType = .none
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.backgroundColor = .clear
        table.gridStyleMask = []
        // 列宽总和 512，远小于视口 586，任何缩放/滚动条情况下都不会裁切
        for (id, title, width) in [("name", "名称", 200.0),
                                   ("vendor", "供应商", 84.0),
                                   ("expires", "到期时间", 148.0),
                                   ("remain", "剩余", 80.0)] {
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

        // ---- 操作按钮 ----
        let addBtn = HoverEffectButton(title: "添加", target: self, action: #selector(addClicked))
        let editBtn = HoverEffectButton(title: "编辑", target: self, action: #selector(editSelected))
        let delBtn = HoverEffectButton(title: "删除", target: self, action: #selector(deleteSelected))
        let refreshBtn = HoverEffectButton(title: "刷新官方", target: self, action: #selector(refreshClicked))
        let cleanBtn = HoverEffectButton(title: "清理过期", target: self, action: #selector(cleanExpired))
        [addBtn, editBtn, delBtn, refreshBtn, cleanBtn].forEach { $0.bezelStyle = .rounded }
        self.editBtn = editBtn
        self.delBtn = delBtn
        self.refreshBtn = refreshBtn
        editBtn.isEnabled = false
        delBtn.isEnabled = false
        let btnCol = NSStackView(views: [addBtn, editBtn, delBtn, NSView(), refreshBtn, cleanBtn])
        btnCol.orientation = .vertical
        btnCol.spacing = 8
        btnCol.translatesAutoresizingMaskIntoConstraints = false

        // ---- 底部设置区（垂直堆叠，天然不会互相重叠）----
        launchCheckbox = NSButton(checkboxWithTitle: "常驻（开机自启+崩溃自动拉起）", target: self, action: #selector(toggleLaunch))
        launchCheckbox.font = .systemFont(ofSize: 10.5)
        launchCheckbox.state = Resident.isInstalled() ? .on : .off
        let folderBtn = HoverEffectButton(title: "打开数据文件夹", target: self, action: #selector(openFolder))
        folderBtn.bezelStyle = .rounded
        folderBtn.controlSize = .small
        let settingsRow = NSStackView(views: [launchCheckbox, NSView(), folderBtn])
        settingsRow.orientation = .horizontal
        settingsRow.spacing = 8

        // 设置写盘失败警示行（写盘成功后自动清除；仅在主线程更新）
        writeWarnLabel.stringValue = "⚠ 设置保存失败，更改未写入磁盘"
        writeWarnLabel.font = .systemFont(ofSize: 10.5)
        writeWarnLabel.textColor = .systemRed
        writeWarnLabel.isHidden = true

        let bottom = NSStackView(views: [settingsRow, writeWarnLabel])
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
            bottom.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            bottom.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),

            settingsRow.widthAnchor.constraint(equalTo: bottom.widthAnchor),
        ])
    }

    func showWindow(_ sender: Any?) {
        window.center()
        window.makeKeyAndOrderFront(sender)
        Motion.reveal(window)
        // 常驻态可能被面板右键菜单（或外部 launchctl）改过，buildWindow 时读的那一次早就失效
        launchCheckbox.state = Resident.isInstalled() ? .on : .off
        // 打开即重取一次数据：窗口隐藏期间 softReload 只更新数组不刷新表格，行序可能停在上次关闭时
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

    /// 与面板同一口径的排序（SubItem.displaySorted）：归档/长期过期的沉到底。
    /// snapshotItems 是纯到期升序，过期几年的垃圾会顶在表头，真正临近的订阅被挤下去。
    private func sortedRows() -> [SubItem] {
        SubItem.displaySorted(panel?.snapshotItems() ?? [])
    }

    private func reloadFromStore() {
        items = sortedRows()
        table.reloadData()
        updateButtonStates()
    }

    /// 每秒轻量刷新：更新倒计时列 + 同步官方数据变化
    private func softReload() {
        // 重排后行号会变，选中项必须按 id 复位：按行号复位会把编辑/删除按钮指到别的条目上
        let sel = table.selectedRow
        let selID = (sel >= 0 && sel < items.count) ? items[sel].id : nil
        items = sortedRows()
        guard window.isVisible, table.window != nil else { return }
        table.reloadData()
        if let selID, let row = items.firstIndex(where: { $0.id == selID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        updateButtonStates()
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtonStates()
    }

    /// 编辑/删除按钮随选中状态启用：未选中置灰，官方条目不可删
    private func updateButtonStates() {
        let row = table.selectedRow
        let item = (row >= 0 && row < items.count) ? items[row] : nil
        editBtn?.isEnabled = item != nil
        delBtn?.isEnabled = item?.isAuto == false
    }

    func tableView(_ tableView: NSTableView, objectValueFor column: NSTableColumn?, row: Int) -> Any? {
        guard row < items.count, let col = column?.identifier.rawValue else { return nil }
        let item = items[row]
        switch col {
        case "name": return item.name
        case "vendor": return item.vendor
        case "expires": return Fmt.absTime(item.expiresAt)
        case "remain": return Fmt.countdownShort(until: item.expiresAt)
        case "source": return item.isAuto ? "官方" : "手动"
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
            alert.runModal()
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
            alert.runModal()
            return
        }
        // 按周划分生成的组：询问删除整组还是仅此条（回车默认 = 取消，防误删）
        if let gid = item.groupID {
            let groupCount = items.filter { $0.groupID == gid }.count
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
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    Store.shared.deleteGroup(gid)
                    reloadFromStore()
                    return
                case .alertSecondButtonReturn:
                    // 组对话框本身就是确认，「仅此条」为显式选择，直接删（与悬浮窗行为一致）
                    Store.shared.deleteManualWithDerived(item.id)
                    reloadFromStore()
                    return
                default:
                    return
                }
            }
        }
        guard DeleteConfirm.run(item, hint: "手动录入的信息删除后不可恢复，需要重新录入") else { return }
        Store.shared.deleteManualWithDerived(item.id)
        reloadFromStore()
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
        let nowOn = Resident.toggle()
        launchCheckbox.state = nowOn ? .on : .off
    }

    /// 删除过期超过归档阈值（3 天，与自动归档同口径）的手动条目：
    /// 官方数据、已归档条目、仍在滚动的额度窗口都不在名单内
    @objc private func cleanExpired() {
        let expired = Store.shared.expiredManualItems()
        guard !expired.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "没有需要清理的条目"
            alert.informativeText = "没有过期超过 3 天的手动条目需要清理。"
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "清理 \(expired.count) 条已过期条目？"
        alert.informativeText = "将删除过期超过 3 天的手动记录（已归档条目与仍在滚动的额度窗口不在此列）：\n"
            + expired.prefix(5).map { "· \($0.name)" }.joined(separator: "\n")
            + (expired.count > 5 ? "\n…" : "")
        alert.addButton(withTitle: "取消")           // 回车默认 = 取消，防误清
        let go = alert.addButton(withTitle: "清理")
        go.hasDestructiveAction = true
        go.contentTintColor = .systemRed
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            Store.shared.deleteManualsWithDerived(expired.map { $0.id })
            reloadFromStore()
        }
    }

    @objc private func openFolder() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        NSWorkspace.shared.open(base.appendingPathComponent("AI到期提醒", isDirectory: true))
    }
}
