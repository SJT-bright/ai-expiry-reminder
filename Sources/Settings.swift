import AppKit

// MARK: - 设置后台：所有订阅的管理窗口
// 悬浮窗只负责展示，添加 / 编辑 / 删除 / 通知配置都在这里完成。

final class SettingsWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!
    private var table: NSTableView!
    private var items: [SubItem] = []
    private var webhookField: NSTextField!
    private var launchCheckbox: NSButton!
    private var editBtn: NSButton!
    private var delBtn: NSButton!
    private var refreshBtn: NSButton!
    private weak var panel: PanelController?
    private var reloadTimer: Timer?

    init(panel: PanelController) {
        self.panel = panel
        super.init()
        buildWindow()
        reloadFromStore()
        reloadTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.softReload()
        }
        if let t = reloadTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 430),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        Glass.glassWindow(window)

        // ---- 条目表格（背景透明，透出玻璃材质）----
        table = NSTableView()
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
        let addBtn = NSButton(title: "添加", target: self, action: #selector(addClicked))
        let editBtn = NSButton(title: "编辑", target: self, action: #selector(editSelected))
        let delBtn = NSButton(title: "删除", target: self, action: #selector(deleteSelected))
        let refreshBtn = NSButton(title: "刷新官方", target: self, action: #selector(refreshClicked))
        let cleanBtn = NSButton(title: "清理过期", target: self, action: #selector(cleanExpired))
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
        let webhookLabel = NSTextField(labelWithString: "飞书群机器人 Webhook（可选，到期前自动推送）")
        webhookLabel.font = .systemFont(ofSize: 10.5)
        webhookLabel.textColor = .secondaryLabelColor

        webhookField = NSTextField(string: Store.shared.state.feishuWebhook)
        webhookField.placeholderString = "https://open.feishu.cn/open-apis/bot/v2/hook/…"
        let testBtn = NSButton(title: "测试发送", target: self, action: #selector(testFeishu))
        testBtn.bezelStyle = .rounded
        let notifyRow = NSStackView(views: [webhookField, testBtn])
        notifyRow.orientation = .horizontal
        notifyRow.spacing = 8

        launchCheckbox = NSButton(checkboxWithTitle: "常驻（开机自启+崩溃自动拉起）", target: self, action: #selector(toggleLaunch))
        launchCheckbox.font = .systemFont(ofSize: 10.5)
        launchCheckbox.state = Resident.isInstalled() ? .on : .off
        let folderBtn = NSButton(title: "打开数据文件夹", target: self, action: #selector(openFolder))
        folderBtn.bezelStyle = .rounded
        folderBtn.controlSize = .small
        let settingsRow = NSStackView(views: [launchCheckbox, NSView(), folderBtn])
        settingsRow.orientation = .horizontal
        settingsRow.spacing = 8

        let bottom = NSStackView(views: [webhookLabel, notifyRow, settingsRow])
        bottom.orientation = .vertical
        bottom.alignment = .leading
        bottom.spacing = 6
        bottom.translatesAutoresizingMaskIntoConstraints = false

        // ---- 玻璃底材 + 顶部标题 ----
        let glass = NSVisualEffectView()
        Glass.apply(glass, corner: 0)
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

            notifyRow.widthAnchor.constraint(lessThanOrEqualTo: bottom.widthAnchor),
            settingsRow.widthAnchor.constraint(equalTo: bottom.widthAnchor),
            webhookField.widthAnchor.constraint(equalToConstant: 380),
        ])
    }

    func showWindow(_ sender: Any?) {
        window.center()
        window.makeKeyAndOrderFront(sender)
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

    private func reloadFromStore() {
        items = panel?.snapshotItems() ?? []
        table.reloadData()
        updateButtonStates()
    }

    /// 每秒轻量刷新：更新倒计时列 + 同步官方数据变化
    private func softReload() {
        items = panel?.snapshotItems() ?? []
        guard window.isVisible, table.window != nil else { return }
        let selected = table.selectedRow
        table.reloadData()
        if selected >= 0 && selected < items.count {
            table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
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
                let choice = alert.runModal()
                if choice == .alertFirstButtonReturn {
                    Store.shared.deleteGroup(gid)
                    reloadFromStore()
                    return
                }
                if choice == .alertSecondButtonReturn {
                    // 组对话框本身就是确认，「仅此条」为显式选择，直接删（与悬浮窗行为一致）
                    Store.shared.deleteManual(id: item.id)
                    reloadFromStore()
                    return
                }
                if choice == .alertThirdButtonReturn { return }
            }
        }
        guard DeleteConfirm.run(item, hint: "手动录入的信息删除后不可恢复，需要重新录入") else { return }
        Store.shared.deleteManual(id: item.id)
        reloadFromStore()
    }

    @objc private func refreshClicked() {
        guard refreshBtn.isEnabled else { return }
        refreshBtn.isEnabled = false
        refreshBtn.title = "刷新中…"
        panel?.refreshData()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.reloadFromStore()
            self.refreshBtn.title = "✓ 已刷新"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                self?.refreshBtn.title = "刷新官方"
                self?.refreshBtn.isEnabled = true
            }
        }
    }

    @objc private func testFeishu() {
        Store.shared.state.feishuWebhook = webhookField.stringValue
        Store.shared.save()
        Feishu.send(webhook: webhookField.stringValue, text: "✅ AI到期提醒：飞书推送配置成功")
    }

    @objc private func toggleLaunch() {
        let nowOn = Resident.toggle()
        Store.shared.state.launchAtLogin = nowOn
        Store.shared.save()
        launchCheckbox.state = nowOn ? .on : .off
    }

    /// 删除过期超过 24 小时的手动条目（官方数据不清理）
    @objc private func cleanExpired() {
        let expired = Store.shared.expiredManualItems()
        guard !expired.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "没有需要清理的条目"
            alert.informativeText = "过期超过 24 小时的手动条目会被清理。"
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "清理 \(expired.count) 条已过期条目？"
        alert.informativeText = "将删除过期超过 24 小时的手动记录：\n"
            + expired.prefix(5).map { "· \($0.name)" }.joined(separator: "\n")
            + (expired.count > 5 ? "\n…" : "")
        alert.addButton(withTitle: "取消")           // 回车默认 = 取消，防误清
        let go = alert.addButton(withTitle: "清理")
        go.hasDestructiveAction = true
        go.contentTintColor = .systemRed
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            Store.shared.deleteManuals(ids: expired.map { $0.id })
            reloadFromStore()
        }
    }

    @objc private func openFolder() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        NSWorkspace.shared.open(base.appendingPathComponent("AI到期提醒", isDirectory: true))
    }
}
