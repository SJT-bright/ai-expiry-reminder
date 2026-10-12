import AppKit

/// 桌面覆盖层与它的短时交互窗口共用层级，避免置顶面板挡住自己的表单/月历。
enum FloatingWindowPolicy {
    static let panelLevel = NSWindow.Level.screenSaver
    static let accessoryLevel = NSWindow.Level(rawValue: panelLevel.rawValue + 1)
    static let spaces: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .stationary, .ignoresCycle
    ]

    static func prepareAccessory(_ window: NSWindow) {
        window.level = accessoryLevel
        window.collectionBehavior = spaces
        window.hidesOnDeactivate = false
    }

    @discardableResult
    static func runAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        prepareAccessory(alert.window)
        return alert.runModal()
    }
}

// MARK: - 删除确认（条目录入成本高，删除必须二次确认）

enum DeleteConfirm {
    /// 弹出确认框，返回 true = 用户确认执行。
    /// 「取消」是回车默认按钮，防止手滑直接回车误删；删除按钮为红色销毁样式，需显式点击。
    @discardableResult
    static func run(_ item: SubItem, verb: String = "删除", hint: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "确认\(verb)「\(item.name)」？"
        alert.informativeText = "到期：\(Fmt.absTime(item.expiresAt))\n\(hint)"
        alert.addButton(withTitle: "取消")
        let go = alert.addButton(withTitle: verb)
        go.hasDestructiveAction = true
        go.contentTintColor = .systemRed
        NSApp.activate(ignoringOtherApps: true)
        // 「取消」是第一按钮（回车默认），确认执行的是第二按钮
        return FloatingWindowPolicy.runAlert(alert) == .alertSecondButtonReturn
    }
}

// MARK: - 液态玻璃

/// 系统液态玻璃（NSGlassEffectView）在本应用里的统一口径。
/// 折射由系统按元素尺寸/圆角算，我们能调的只有 style、cornerRadius、tintColor：
/// · .clear 通透、边缘折射明显（实测能看见背后壁纸的颜色与字形被扭动）；
/// · .regular 偏暗偏实，接近传统毛玻璃——本应用一律用 .clear。
/// 底板着色稳住浅色背景上的白字；列表行透明，直接共享底板的玻璃。
/// 输入框与编辑卡仍使用独立玻璃，承担控件边界。
enum Glass {
    /// 实时读取（原为 `static let`：枚举里的静态常量是懒存一次的，用户在系统设置里
    /// 改了「降低透明度」要重启才生效，与 `Motion.reduceMotion` 的口径也不一致）。
    static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    /// 面板/窗口底板的着色：够暗以稳住白字，又不至于把折射压平
    static var bodyTint: NSColor { NSColor(white: 0.02, alpha: reduceTransparency ? 0.95 : 0.60) }

    /// 一块玻璃。contentView 为空时按兄弟子视图压在上面的方式用（面板底板就是这种）。
    static func make(cornerRadius: CGFloat, tint: NSColor?, style: NSGlassEffectView.Style = .clear) -> NSGlassEffectView {
        let g = NSGlassEffectView()
        g.style = style
        g.cornerRadius = cornerRadius
        g.tintColor = tint
        g.appearance = NSAppearance(named: .darkAqua)
        return g
    }

    /// 只做背景的装饰玻璃板：不截获点击，内容仍由同级的上层视图负责接收事件。
    /// 底板、编辑卡都用它——否则点在玻璃上的那一下会被它吃掉，控件就点不动了。
    static func plate(cornerRadius: CGFloat, tint: NSColor?) -> GlassPlate {
        GlassPlate(cornerRadius: cornerRadius, tint: tint)
    }

    /// 让一个带标题栏的窗口变成透明玻璃窗
    static func glassWindow(_ w: NSWindow) {
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.styleMask.insert(.fullSizeContentView)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.appearance = NSAppearance(named: .darkAqua)
    }

    /// 内层卡片/输入框的玻璃着色。
    /// 这些元素叠在已着色的底板之上，自己又是一层 .clear 玻璃——两层折射叠加会把它们
    /// 提亮成乳白药丸（用户截图实测），所以补一层暗 tint 把自身压回与底板同材质。
    static var cardTint: NSColor { NSColor(white: 0.02, alpha: reduceTransparency ? 0.92 : 0.52) }

    /// 内层卡片/输入框用的玻璃（带 cardTint），与底板区分开但同色系
    static func card(cornerRadius: CGFloat) -> GlassPlate {
        GlassPlate(cornerRadius: cornerRadius, tint: cardTint)
    }

    /// 把输入框包成一块小玻璃。
    /// 非做不可的原因：NSTextField/NSComboBox 默认带系统不透明底色 textBackgroundColor
    /// 加一圈边框，放进玻璃窗就是几块死板的深色贴片（实测截图里名称、到期时间、
    /// 首次重置、供应商四行全这样）。这里剥掉自身底色与边框，改由玻璃片承担边界。
    static func fielded<V: NSView>(_ field: V, corner: CGFloat = 7) -> NSView {
        if let t = field as? NSTextField {
            t.drawsBackground = false
            t.isBezeled = false
            t.isBordered = false
        }
        if let c = field as? NSComboBox {
            c.drawsBackground = false
        }
        let box = NSView()
        let plate = Glass.card(cornerRadius: corner)
        let calendarField = field as? DateTextField
        let calendarButton: NSButton? = calendarField.map { dateField in
            let button = NSButton()
            button.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "选择日期")
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = "打开日历选择日期"
            button.setAccessibilityLabel("打开日历选择日期")
            button.setAccessibilityIdentifier("\(dateField.accessibilityIdentifier())CalendarButton")
            button.target = dateField
            button.action = #selector(DateTextField.calendarButtonClicked(_:))
            button.translatesAutoresizingMaskIntoConstraints = false
            return button
        }
        plate.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(plate)
        box.addSubview(field)
        if let calendarButton { box.addSubview(calendarButton) }
        NSLayoutConstraint.activate([
            plate.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            plate.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            plate.topAnchor.constraint(equalTo: box.topAnchor),
            plate.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            // 原来靠 bezel 自带的内边距，剥掉边框后自己补回来
            field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
            field.topAnchor.constraint(equalTo: box.topAnchor, constant: 2),
            field.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
        ])
        if let calendarButton {
            NSLayoutConstraint.activate([
                field.trailingAnchor.constraint(equalTo: calendarButton.leadingAnchor, constant: -2),
                calendarButton.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -3),
                calendarButton.centerYAnchor.constraint(equalTo: box.centerYAnchor),
                calendarButton.widthAnchor.constraint(equalToConstant: 22),
                calendarButton.heightAnchor.constraint(equalToConstant: 22),
            ])
        } else {
            field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6).isActive = true
        }
        // 包一层就得把"愿意被拉长"这件事显式声明回来：NSGridView 靠单元格的贴合优先级
        // 决定要不要把格子撑满列宽，默认的 250 会让空内容的名称框塌成一个小方块
        // （实测：名称框只剩一个字符宽、供应商下拉缩成箭头）。
        box.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
        box.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .vertical)
        box.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
        return box
    }
}

/// 不截获点击的玻璃板（`Glass.plate` 的实现载体）
final class GlassPlate: NSGlassEffectView {
    init(cornerRadius: CGFloat, tint: NSColor?) {
        super.init(frame: .zero)
        style = .clear
        self.cornerRadius = cornerRadius
        tintColor = tint
        appearance = NSAppearance(named: .darkAqua)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 面板玻璃宿主：内容经系统 contentView 承载，圆角由玻璃自己算。
final class GlassSurface: NSView {
    private let glass: NSGlassEffectView
    /// 圆角变化（胶囊 9 ↔ 面板 18）走呈现层过渡：值没变时不动画，
    /// 窗口尺寸动画期间逐帧 layout 重复赋同一值也不会重启动画。
    var cornerRadius: CGFloat = 18 {
        didSet {
            guard cornerRadius != oldValue else { return }
            glass.wantsLayer = true
            if Motion.canAnimate, let layer = glass.layer {
                let anim = CABasicAnimation(keyPath: "cornerRadius")
                anim.fromValue = (layer.presentation() ?? layer).cornerRadius
                anim.toValue = cornerRadius
                anim.duration = 0.3
                anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(anim, forKey: "motionRadius")
            }
            glass.cornerRadius = cornerRadius
        }
    }
    /// 胶囊与展开面板共用同一玻璃着色。
    var tint: NSColor? {
        get { glass.tintColor }
        set { glass.tintColor = newValue }
    }
    var materialAppearance: NSAppearance? {
        get { glass.appearance }
        set { glass.appearance = newValue }
    }
    override init(frame: NSRect) {
        glass = Glass.make(cornerRadius: 18, tint: Glass.bodyTint)
        super.init(frame: frame)
        addSubview(glass)
        // 不设 false 就等于让自动尺寸掩码和这四条约束打架：收起成胶囊时内层玻璃拿不到
        // 正确 frame，着色直接消失（实测胶囊变全透）。
        glass.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    /// 系统只保证 contentView 在玻璃上方；交互内容不能作为玻璃的兄弟视图。
    var contentView: NSView? {
        get { glass.contentView }
        set { glass.contentView = newValue }
    }
}

/// 小胶囊悬停只提亮轮廓，不缩放或移动文字，不改变玻璃透明度。
final class PillHoverOutline: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.8, dy: 0.8)
        let outline = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor(white: 1, alpha: 0.26).setStroke()
        outline.lineWidth = 0.65
        outline.stroke()
    }
}

// MARK: - 无边框悬浮面板

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 胶囊展开后的底部控制区，与列表共用同一窗口和玻璃底板。
final class CapsuleControlsView: NSView {
    static let height: CGFloat = 60
    let autoCollapseButton = NSButton(checkboxWithTitle: "移开鼠标 8 秒后自动收起", target: nil, action: nil)
    let moreMenu = NSMenu()
    private let divider = NSView()
    private var buttons: [NSButton] = []
    var onCollapse: (() -> Void)?
    var onRestore: (() -> Void)?
    var onRestoreMenuBar: (() -> Void)?
    var onHide: (() -> Void)?
    var onSettings: (() -> Void)?
    var onAutoCollapse: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        setAccessibilityIdentifier("capsuleControls")
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(white: 1, alpha: 0.15).cgColor
        addSubview(divider)
        func button(_ title: String, _ action: Selector, _ id: String, _ help: String) {
            let button = HoverEffectButton(title: title, target: self, action: action)
            button.isBordered = false
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.contentTintColor = .white
            button.restFill = NSColor(white: 1, alpha: 0.08)
            button.setAccessibilityIdentifier(id)
            button.toolTip = help
            buttons.append(button)
            addSubview(button)
        }
        button("收起", #selector(collapse), "panelControlCollapse", "收起为倒计时胶囊")
        button("归位", #selector(restore), "panelControlRestore", "收起并回到本屏右上角")
        button("管理", #selector(settings), "panelControlSettings", "管理提醒记录")
        button("更多", #selector(showMore(_:)), "panelControlMore", "隐藏悬浮窗或恢复顶部菜单栏入口")
        for (title, action, id) in [("暂时隐藏悬浮窗", #selector(hidePanel), "panelControlHide"),
                                    ("恢复顶部菜单栏图标", #selector(restoreMenuBar), "panelControlRestoreMenuBar")] {
            let item = moreMenu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.setAccessibilityIdentifier(id)
        }
        autoCollapseButton.target = self
        autoCollapseButton.action = #selector(autoCollapseChanged)
        autoCollapseButton.font = .systemFont(ofSize: 10)
        autoCollapseButton.setAccessibilityIdentifier("panelControlAutoCollapse")
        addSubview(autoCollapseButton)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        divider.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 0.5)
        let gap: CGFloat = 5
        let width = (bounds.width - gap * 3) / 4
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: CGFloat(index) * (width + gap), y: 26, width: width, height: 24)
        }
        autoCollapseButton.frame = NSRect(x: 0, y: 1, width: bounds.width, height: 20)
    }
    func refresh() {
        autoCollapseButton.state = Store.shared.state.panelAutoCollapse ? .on : .off
    }
    @objc private func showMore(_ sender: NSButton) {
        moreMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 3), in: sender)
    }
    @objc private func collapse() { onCollapse?() }
    @objc private func restore() { onRestore?() }
    @objc private func restoreMenuBar() { onRestoreMenuBar?() }
    @objc private func hidePanel() { onHide?() }
    @objc private func settings() { onSettings?() }
    @objc private func autoCollapseChanged() { onAutoCollapse?(autoCollapseButton.state == .on) }
}

/// 容器视图：跟踪鼠标进出（自动收起），并处理「收起态点击展开」
final class PanelContainerView: NSView {
    var onMouseEnter: (() -> Void)?
    var onMouseExit: (() -> Void)?
    var onBackgroundClick: (() -> Void)?
    private var pressPoint: NSPoint?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func accessibilityPerformPress() -> Bool {
        guard accessibilityRole() == .button else { return false }
        onBackgroundClick?()
        return true
    }

    override func mouseEntered(with event: NSEvent) { onMouseEnter?() }
    override func mouseExited(with event: NSEvent) { onMouseExit?() }

    // 点击在松开时提交，拖动超过阈值则交给窗口；按下就展开会吞掉胶囊拖动。
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        pressPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressPoint else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) >= 4 else { return }
        pressPoint = nil
        window?.performDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard pressPoint != nil else { return }
        pressPoint = nil
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onBackgroundClick?()
        }
    }

}

// MARK: - 行区裁剪视口（高度受限时滚动）

/// 展开面板行区的视口：用 layer 裁剪超出可视预算的行容器，滚轮平移内容。
/// 面板是纯手动布局（Auto Layout 在无边框面板上会把窗口求解成 0×0），不引入 NSScrollView。
final class RowsClipView: NSView {
    var onScroll: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY
        guard dy != 0 else { return }
        onScroll?(dy)
    }
}

// MARK: - 分区标题（细色条分隔）

final class SectionHeaderView: NSView {
    init(title: String) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 7.5, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true

        addSubview(label)
        addSubview(line)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 14)
    }
}

// MARK: - 条目行视图（紧凑双行）

final class RowView: NSView {
    private let dot = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private let countdownLabel = NSTextField(labelWithString: "")
    private let deleteBtn = HoverEffectButton(title: "✕", target: nil, action: nil)
    private let barTrack = NSView()
    private let barFill = NSView()
    // 行背景保持透明：叠加第二层玻璃会产生乳白蒙层，文字直接共享面板底板。
    private var barFillWidth: NSLayoutConstraint?
    /// 上一次渲染的紧迫色档（refreshCountdown 比较用）：色档没变就不碰 layer 与文本颜色
    private var renderedColor: NSColor?
    private(set) var item: SubItem?
    var onOpen: ((SubItem) -> Void)?
    var onDelete: ((SubItem) -> Void)?
    var onReminder: ((SubItem) -> Void)?
    var onContextMenu: ((NSMenu, NSEvent, NSView) -> Void)?

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 28)
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        deleteBtn.target = self
        deleteBtn.action = #selector(deleteTapped)
        deleteBtn.isBordered = false          // 无边框：干净的字形按钮，不是小方块
        deleteBtn.font = .systemFont(ofSize: 13, weight: .medium)
        deleteBtn.contentTintColor = .secondaryLabelColor
        for v in [dot, nameLabel, subLabel, countdownLabel, deleteBtn, barTrack, barFill] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 2.5
        barTrack.wantsLayer = true
        barTrack.layer?.backgroundColor = NSColor(white: 1, alpha: 0.10).cgColor
        barTrack.layer?.cornerRadius = 1
        barFill.wantsLayer = true
        barFill.layer?.backgroundColor = NSColor(white: 1, alpha: 0.35).cgColor
        barFill.layer?.cornerRadius = 1

        nameLabel.font = .systemFont(ofSize: 10, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        countdownLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        subLabel.font = .systemFont(ofSize: 7.5)
        subLabel.textColor = .secondaryLabelColor
        subLabel.lineBreakMode = .byTruncatingMiddle

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            dot.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 5),
            dot.heightAnchor.constraint(equalToConstant: 5),

            nameLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            // 双行文本块垂直重心：上空 2.5 ≈ 副标题与进度条之间空 2，避免文字头贴顶
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2.5),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: countdownLabel.leadingAnchor, constant: -8),

            // 倒计时与名称字体不同（等宽半粗 vs 系统），按基线对齐才不会出现半像素高低差
            countdownLabel.lastBaselineAnchor.constraint(equalTo: nameLabel.lastBaselineAnchor),
            countdownLabel.trailingAnchor.constraint(equalTo: deleteBtn.leadingAnchor, constant: -4),

            deleteBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            deleteBtn.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            deleteBtn.widthAnchor.constraint(equalToConstant: 16),

            subLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            // 副标题必须停在 ✕ 之前：钉到 trailingAnchor 会让长副标题从 ✕ 底下穿过去（实测可见）
            subLabel.trailingAnchor.constraint(lessThanOrEqualTo: deleteBtn.leadingAnchor, constant: -4),
            subLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 0.5),

            barTrack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            barTrack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            barTrack.bottomAnchor.constraint(equalTo: bottomAnchor),
            barTrack.heightAnchor.constraint(equalToConstant: 2),
            barFill.leadingAnchor.constraint(equalTo: barTrack.leadingAnchor),
            barFill.centerYAnchor.constraint(equalTo: barTrack.centerYAnchor),
            barFill.heightAnchor.constraint(equalToConstant: 2),

        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // 标签不独立处理右键，整行统一接收；删除按钮仍保留左键行为。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === deleteBtn || hit.isDescendant(of: deleteBtn) { return hit }
        return self
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let current = NSMenuItem(title: ReminderTiming.label(hours: Store.shared.reminderHours(for: item.id)), action: nil, keyEquivalent: "")
        current.isEnabled = false
        menu.addItem(current)
        let edit = NSMenuItem(title: "提前提醒…", action: #selector(reminderTapped), keyEquivalent: "")
        edit.target = self
        edit.isEnabled = true
        menu.addItem(edit)
        return menu
    }

    @objc private func reminderTapped() {
        guard let item else { return }
        onReminder?(item)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        if let onContextMenu { onContextMenu(menu, event, self) }
        else { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        Motion.press(self, pressed: true)
        guard let item else { return }
        onOpen?(item)
    }

    override func mouseUp(with event: NSEvent) {
        Motion.press(self, pressed: false)
    }

    override func mouseExited(with event: NSEvent) {
        Motion.press(self, pressed: false)
        Motion.float(self, on: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // 必须先移除旧的：面板每次布局/尺寸变化都会重走这里，只加不删会让追踪区
        // 越积越多（同文件 PanelContainerView 与 Motion 的 HoverEffectButton 都做了清理）。
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    /// 悬停反馈：整行轻微垂直浮起；背景始终透明，移出落下。
    /// 不做横向缩放——近满宽的行以中心放大会把行内文字左右各推出 4pt+，与邻行错位（观感「浮歪」）
    override func mouseEntered(with event: NSEvent) {
        Motion.float(self, on: true, scale: 1.0, lift: 1.2)
    }

    @objc private func deleteTapped() {
        guard let item else { return }
        onDelete?(item)
    }

    override var mouseDownCanMoveWindow: Bool { false }   // 行区域点击不拖动面板

    /// 条目数据变化后原位刷新（内联编辑时用）
    func updateItem(_ item: SubItem) {
        self.item = item
        configure(item, now: Date())
    }

    /// 每秒心跳：只更新倒计时文本与颜色档（先比较旧值再写）。
    /// 不走 configure()：那里每次都拆建进度条的 width 约束（multiplier 只能重建），
    /// 每秒对每行调用会让额度条闪一下（实测）。
    func refreshCountdown(now: Date) {
        guard let item else { return }
        let color = Self.urgencyColor(item, now: now)
        let text = Fmt.countdown(until: item.expiresAt, now: now)
        if countdownLabel.stringValue != text { countdownLabel.stringValue = text }
        guard color != renderedColor else { return }
        renderedColor = color
        countdownLabel.textColor = color
        dot.layer?.backgroundColor = color.cgColor
        toolTip = Self.detailTooltip(item, now: now)
    }

    func configure(_ item: SubItem, now: Date) {
        self.item = item
        let color = Self.urgencyColor(item, now: now)
        renderedColor = color
        dot.layer?.backgroundColor = color.cgColor
        var prefix = ""
        if let usedRaw = item.usedPercent {
            // 官方推来的百分比可能越界（>100 或 <0）：进度条本来就钳过，
            // 文本必须同口径钳，否则显示「剩余-7%」。
            let used = min(max(usedRaw, 0), 100)
            subLabel.stringValue = "\(item.vendor) · \(Fmt.absTime(item.expiresAt)) · 剩余\(Int(100 - used))%"
            let ratio = CGFloat(used) / 100.0
            barFillWidth?.isActive = false
            // multiplier 必须为正：额度刚好用 0% 时传 0 会让 NSLayoutConstraint 直接抛异常
            barFillWidth = barFill.widthAnchor.constraint(equalTo: barTrack.widthAnchor,
                                                          multiplier: max(ratio, 0.001))
            barFillWidth?.isActive = true
            barTrack.isHidden = false
            barFill.isHidden = false
            // 消耗节奏：已用比例明显超前时间进度 → ⚡（借鉴 reset-aware pace）
            if used < 100, Self.paceDelta(item, now: now) >= 15 {
                prefix = "⚡ "
            }
        } else {
            subLabel.stringValue = "\(item.vendor) · \(Fmt.absTime(item.expiresAt)) · \(item.isAuto ? "官方" : "手动")"
            barTrack.isHidden = true
            barFill.isHidden = true
        }
        nameLabel.stringValue = prefix + item.name
        countdownLabel.stringValue = Fmt.countdown(until: item.expiresAt, now: now)
        countdownLabel.textColor = color
        toolTip = Self.detailTooltip(item, now: now)
    }

    /// 已用百分比 − 时间进度百分比（正值 = 消耗快于时间流逝）
    static func paceDelta(_ item: SubItem, now: Date) -> Double {
        guard let used = item.usedPercent, let h = item.repeatHours, h > 0 else { return 0 }
        let window = h * 3600
        let start = item.expiresAt.addingTimeInterval(-window)
        let elapsed = now.timeIntervalSince(start) / window * 100
        return used - min(max(elapsed, 0), 100)
    }

    static func detailTooltip(_ item: SubItem, now: Date) -> String {
        // 仅额度重置窗口展示「下次重置」；手动通用周期窗口仍是「到期」
        let verb = item.isQuotaResetWindow ? "下次重置" : "到期"
        var lines = ["\(item.vendor) · \(item.name)",
                     "\(verb)：\(Fmt.absTime(item.expiresAt))（\(Fmt.countdown(until: item.expiresAt, now: now))）",
                     "来源：\(item.isAuto ? "官方本地数据" : "手动添加")",
                     "提醒：\(ReminderTiming.label(hours: Store.shared.reminderHours(for: item.id)))（右键可修改）"]
        if let used = item.usedPercent {
            let clamped = min(max(used, 0), 100)   // 与行内文本同口径钳位，别在 tooltip 里露出负数
            var pace = "额度剩余 \(Int(100 - clamped))%"
            let delta = paceDelta(item, now: now)
            if delta >= 15 { pace += " · ⚡消耗快于时间进度" }
            lines.append(pace)
        }
        if !item.note.isEmpty { lines.append(item.note) }
        return lines.joined(separator: "\n")
    }

    /// 颜色规则：额度用尽（0%）白色提示；到期前 24h 与过期 24h 内红色；
    /// 过期更久转灰（临近 3 天自动归档），其余全绿
    static func urgencyColor(_ item: SubItem, now: Date) -> NSColor {
        let remain = item.expiresAt.timeIntervalSince(now)
        if let used = item.usedPercent, used >= 100 {
            return NSColor(white: 0.92, alpha: 1)                                // 额度耗尽：白色
        }
        if remain < -24 * 3600 {
            return NSColor(white: 0.55, alpha: 1)                                // 过期超 1 天：灰
        }
        if remain <= 24 * 3600 {
            return NSColor(red: 1.0, green: 0.32, blue: 0.30, alpha: 1)          // 24 小时内：红
        }
        return NSColor(red: 0.22, green: 0.80, blue: 0.36, alpha: 1)             // 其余：绿
    }
}

// MARK: - 日期时间输入（点日期弹月历 / 点时·分段键入）

/// 一个框承载完整 yyyy-MM-dd HH:mm：stringValue 始终是整串（保存路径与自测都读它），
/// 但框内各段各有手感：
/// · 点日期段 → 就地弹月历选日，时:分原样保留，选完把光标直接交给「时」段；
/// · 点时/分段 → 整段选中，数字按「个位→十位」左移（1→3 得 13；9→3 超上限则重起个位），
///   ←/→ 在时、分之间跳段，↑/↓ 该段 ±1，失焦补零规范化；
/// · 没经鼠标点选（程序化 setText、自测直接喂字段编辑器）时分段逻辑全哑，
///   仍走原模板过滤 + 严格解析，逐键行为与改造前一致。
/// 仍不用 NSDatePicker 文本样式：它吞前导零、段间乱跳，月历又是系统皮肤、贴不上暗色玻璃。
/// 键入全程经模板过滤（垃圾字符剔除、段内位数封顶，往「天」里敲 3333300 在第 3 位就进不来），
/// 失焦/回车时严格解析生效（拒绝 2026/10/99 的进位滚动），失败红框提示并保留上一有效值。
final class DateTextField: NSTextField, NSTextFieldDelegate {
    /// 解析成功后的生效时点（保存路径读取此值，而非文本内容）
    private(set) var date: Date
    var onValidChange: ((Date) -> Void)?

    /// 框内可点选的数字段
    enum Segment: Equatable {
        case date, hour, minute
        /// 两位数字段的取值上限（日期段是年月日合体，不做数值判断）
        var maxValue: Int {
            switch self {
            case .date: return 99
            case .hour: return 23
            case .minute: return 59
            }
        }
        /// ←/→、Tab 的跳段顺序
        func stepped(_ dir: Int) -> Segment {
            let all = [Segment.date, .hour, .minute]
            let i = all.firstIndex(of: self) ?? 0
            return all[min(max(i + dir, 0), all.count - 1)]
        }
    }
    private(set) var segment: Segment?
    /// 段内「个位→十位」左移的中间累计值
    private var pending: Int?
    /// 自己改写编辑器内容期间的重入闸：replaceCharacters 会再触发一次
    /// controlTextDidChange，不挡住的话分段进位会自己吃自己
    private var mutatingText = false
    /// 编辑期间监视方向键的本地监视器；只在有段被点选时吞键
    private var keyMonitor: Any?

    /// 显示/回填用；解析一律走 parseDateText 的严格规则
    /// （lenient 会把超界字段滚动成离谱日期：2026/10/3333300 → 11153 年）
    private let dateParser: DateFormatter = {
        let f = DateFormatter()
        // 分隔符与 Fmt.absTime 同口径（yyyy-MM-dd HH:mm），全应用一个样；
        // 解析一律走 parseDateText 的严格规则，两种分隔符都收（commitTemplate 允许 [/-]）
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = .current
        return f
    }()

    /// 键入模板：yyyy/MM/dd HH:mm 的前缀形态（容忍 - 分隔与单数字段），
    /// 每段位数封顶——年 4 位、月/日 2 位、时/分 2 位
    private static let inputTemplate = try! NSRegularExpression(
        pattern: #"^\d{0,4}([/-]\d{0,2}([/-]\d{0,2}( \d{0,2}(:\d{0,2})?)?)?)?$"#)

    /// 提交格式：完整日期+时间；越界段（月>12、日>31、时>23、分>59）一律拒绝
    private static let commitTemplate = try! NSRegularExpression(
        pattern: #"^(\d{4})[/\-](\d{1,2})[/\-](\d{1,2}) (\d{1,2}):(\d{1,2})$"#)

    init(date: Date, identifier: String) {
        self.date = date
        super.init(frame: .zero)
        stringValue = dateParser.string(from: date)
        font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        setAccessibilityIdentifier(identifier)
        delegate = self   // 键入全程经 controlTextDidChange 净化（Formatter 改写在 field editor 链路不生效）
        toolTip = "点击日期弹出月历选日；点击「时」或「分」直接键入数字（个位→十位，←/→ 跳段，↑/↓ 加减）"
        // 禁止折行：日期串必须单行完整显示（否则被容器挤压时折叠成两行、下半被裁）
        if let cell = cell as? NSTextFieldCell {
            cell.wraps = false
            cell.usesSingleLineMode = true
            cell.lineBreakMode = .byClipping
        }
    }

    /// 最小固有宽度 = 整串日期的实际渲染宽 + 光标边距：Grid/Stack 再挤压也不折叠
    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize
        let sample = dateParser.string(from: date)
        let w = ceil((sample as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 11)]).width) + 10
        s.width = max(s.width, w)
        return s
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 程序化设置（快捷按钮、月历回填）：重写文本并清除错误态
    func setDate(_ d: Date) {
        date = d
        segment = nil
        pending = nil
        stringValue = dateParser.string(from: d)
        wantsLayer = true
        layer?.backgroundColor = nil
    }

    /// 测试/程序化入口：写入原始文本并立即提交解析
    func setText(_ text: String) {
        segment = nil
        pending = nil
        stringValue = text
        commit()
    }

    // MARK: - 点选分段 / 弹月历

    /// 点到哪一段就进哪一段的编辑态：日期段弹月历，时/分段整段选中等键入。
    /// 先让 super 走完系统起编辑、落光标的流程，再按点中的字符位改写选区，
    /// 这样点选分段与拖拽选区互不干扰。
    /// 未激活状态下的第一下点击也要送进 mouseDown，而不是被系统吞去激活应用：
    /// 日期段是「点一下就弹月历」，吞首击就得点两次才出得来（真 HID 点击实测到的）。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // 宿主窗没成 key（应用没抢到前台）时 super 不会起编辑，这里自己补一次首响应，
        // 否则点选分段与弹月历全都落空——月历本身不需要键盘，不该被激活状态卡住。
        if currentEditor() == nil { window?.makeFirstResponder(self) }
        guard let editor = currentEditor() as? NSTextView else { segment = nil; return }
        let hit = Self.segment(at: editor.characterIndexForInsertion(
                                 at: editor.convert(event.locationInWindow, from: nil)),
                               in: editor.string)
        guard let hit else { segment = nil; pending = nil; return }
        switch hit {
        case .date:
            selectSegment(.date, in: editor)
            openCalendar()
        case .hour, .minute:
            selectSegment(hit, in: editor)
        }
    }

    override func textDidBeginEditing(_ notification: Notification) {
        super.textDidBeginEditing(notification)
        installKeyMonitor()
    }

    override func textDidEndEditing(_ notification: Notification) {
        removeKeyMonitor()
        super.textDidEndEditing(notification)
        segment = nil
        pending = nil
        // 失焦/点别处仍提交；只有回车且解析成功才出声（setText / 程序化 commit 不走这里）
        let movement = notification.userInfo?[NSText.movementUserInfoKey] as? Int
        if commit(), movement == NSReturnTextMovement {
            Motion.playTap()
        }
    }

    deinit { removeKeyMonitor() }

    /// 点日期段 → 就地弹月历。先结束编辑把文本落回 cell，程序化回填才生效。
    /// internal：mouseDown 的落点，也是自测驱动月历接线的入口。
    func openCalendar() {
        guard let window else { return }
        let anchor = convert(bounds, to: nil)      // 月历按宿主窗 view 坐标系定位
        // 先按可见文本判有效性：文本敲坏了时 date 还是上一轮的旧值，直接拿它预选会让用户
        // 选完日把刚敲的年/月静默覆盖掉。无效态交给月历走「不预选、确认也不回填」分支。
        let textIsValid = commit()
        window.makeFirstResponder(nil)
        CalendarPickerController.shared.present(initial: date, initialIsValid: textIsValid,
                                                anchorRect: anchor, in: window) { [weak self] picked in
            guard let self = self else { return }
            self.setDate(picked)
            self.onValidChange?(picked)
            self.beginTimeEntry()
        }
    }

    @objc func calendarButtonClicked(_ sender: NSButton) { openCalendar() }

    /// 选完日期顺手把「时」段选中：日历管日期、键盘管时间，一路敲完不用回头再点
    private func beginTimeEntry() {
        guard let window else { return }
        window.makeFirstResponder(self)
        if let editor = currentEditor() as? NSTextView { selectSegment(.hour, in: editor) }
    }

    /// 编辑期间拦方向键/Tab：只在有段被点选时生效，其余按键（回车保存、Esc 取消）原样放行。
    /// 不换字段编辑器实现：窗口的 field editor 全窗口共用，换掉会波及名称、供应商输入框。
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self = self,
                  let editor = self.currentEditor() as? NSTextView,
                  self.window?.firstResponder === editor,
                  let seg = self.segment else { return ev }
            switch ev.keyCode {
            case 123, 124:                                   // ←/→ 在日期、时、分之间跳段
                self.selectSegment(seg.stepped(ev.keyCode == 124 ? 1 : -1), in: editor)
            case 125, 126:                                   // ↓/↑ 该段 ±1（日期段整天挪）
                self.bump(seg, by: ev.keyCode == 126 ? 1 : -1, in: editor)
            case 48:                                         // Tab / ⇧Tab
                self.selectSegment(seg.stepped(ev.modifierFlags.contains(.shift) ? -1 : 1), in: editor)
            default:
                return ev
            }
            return nil
        }
    }

    private func removeKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    // MARK: - 分段定位与进位

    /// 按数字 run 顺序对齐模板切段：年、月、日、时、分。
    /// 只认「连续数字算一段」，所以残缺串（2026-10-3）也定得区位。
    static func digitRuns(_ text: String) -> [NSRange] {
        let ns = text as NSString
        var runs: [NSRange] = []
        var i = 0
        while i < ns.length {
            guard Self.isDigit(ns.character(at: i)) else { i += 1; continue }
            let start = i
            while i < ns.length, Self.isDigit(ns.character(at: i)) { i += 1 }
            runs.append(NSRange(location: start, length: i - start))
        }
        return runs
    }

    private static func isDigit(_ u: unichar) -> Bool { u >= 48 && u <= 57 }

    /// 点到的字符位置属于哪一段（段后紧邻的分隔符算下一段）
    static func segment(at index: Int, in text: String) -> Segment? {
        let runs = digitRuns(text)
        guard !runs.isEmpty else { return nil }
        if index <= NSMaxRange(runs[min(3, runs.count) - 1]) { return .date }
        guard runs.count >= 4 else { return .hour }
        return index <= NSMaxRange(runs[3]) ? .hour : .minute
    }

    /// 段 → 已敲出部分的字符范围
    private func range(for seg: Segment, in ns: NSString) -> NSRange? {
        let runs = Self.digitRuns(ns as String)
        switch seg {
        case .date:
            guard !runs.isEmpty else { return nil }
            return NSRange(location: runs[0].location,
                           length: NSMaxRange(runs[min(3, runs.count) - 1]) - runs[0].location)
        case .hour:   return runs.count >= 4 ? runs[3] : nil
        case .minute: return runs.count >= 5 ? runs[4] : nil
        }
    }

    /// 段 → 选区；该段还没敲出来时先补上它前面的分隔符，让数字有落点
    private func editableRange(for seg: Segment, in editor: NSTextView) -> NSRange? {
        let ns = editor.string as NSString
        if let run = range(for: seg, in: ns) { return run }
        let runs = Self.digitRuns(editor.string)
        switch seg {
        case .date: return nil
        case .hour where runs.count >= 3: return append(" ", at: ns.length, in: editor)
        case .minute where runs.count >= 4: return append(":", at: ns.length, in: editor)
        default: return nil
        }
    }

    private func append(_ separator: String, at end: Int, in editor: NSTextView) -> NSRange {
        mutatingText = true
        if !editor.string.hasSuffix(separator) {
            editor.replaceCharacters(in: NSRange(location: end, length: 0), with: separator)
        }
        mutatingText = false
        return NSRange(location: (editor.string as NSString).length, length: 0)
    }

    /// 整段选中就是「正在改这一段」的可见反馈（吃系统选区高亮），同时复位个位累计。
    /// internal：自测直接调它模拟点选，走的与 mouseDown 同一入口。
    func selectSegment(_ seg: Segment, in editor: NSTextView) {
        guard let run = editableRange(for: seg, in: editor) else { segment = nil; return }
        segment = seg
        pending = nil
        editor.setSelectedRange(run)
        editor.needsDisplay = true
    }

    /// 段内「个位→十位」进位规则（纯函数，自测直接喂）：整段选中后敲进来的数字当作个位 d，
    /// 与已累计值合并（pending=1 敲 3 → 13）；合并越过段上限就丢掉已累计的、以 d 重起个位
    /// （pending=9 敲 3：93 > 23 → 3）。分钟上限 59，个位敲 5 之后怎么敲都还能合并。
    /// 返回该段应显示的字面与新的累计值——不足两位不补零，「个位」得让用户看得见，
    /// 补零统一留到 commit。
    static func shift(pending: Int?, digits: String, cap: Int) -> (written: String, pending: Int?) {
        guard let typed = Int(digits), let tail = digits.last, let d = Int(String(tail)) else {
            return ("", nil)
        }
        let merged = digits.count == 1 ? (pending ?? 0) * 10 + typed : typed
        let value = merged <= cap ? merged : d
        return (value < 10 ? String(value) : String(format: "%02d", value), value)
    }

    /// 把进位规则落到当前段的字面上，并把选区重新盖住整段
    private func applySegmentDigit(_ editor: NSTextView) {
        guard !mutatingText, let seg = segment, seg != .date else { return }
        let ns = editor.string as NSString
        guard let run = range(for: seg, in: ns), run.length > 0 else { pending = nil; return }
        let text = ns.substring(with: run)
        let digits = text.filter { $0 >= "0" && $0 <= "9" }
        let (written, next) = Self.shift(pending: pending, digits: digits, cap: seg.maxValue)
        pending = next
        guard !written.isEmpty, written != text else { editor.setSelectedRange(run); return }
        mutatingText = true
        editor.replaceCharacters(in: run, with: written)
        mutatingText = false
        reselect(seg, in: editor)
    }

    /// ↑/↓：日期段整天挪，时/分段数值 ±1，越界回绕（23→0、0→23）
    private func bump(_ seg: Segment, by dir: Int, in editor: NSTextView) {
        if seg == .date {
            let d = date.addingTimeInterval(TimeInterval(dir) * 86400)
            date = d
            mutatingText = true
            editor.string = dateParser.string(from: d)
            mutatingText = false
            selectSegment(.date, in: editor)
            onValidChange?(d)
            return
        }
        guard let run = editableRange(for: seg, in: editor) else { return }
        let span = editor.string as NSString
        let cur = run.length == 0 ? (pending ?? 0) : (Int(span.substring(with: run)) ?? 0)
        let wrap = seg.maxValue + 1
        let value = ((cur + dir) % wrap + wrap) % wrap
        pending = value
        mutatingText = true
        editor.replaceCharacters(in: run, with: String(format: "%02d", value))
        mutatingText = false
        reselect(seg, in: editor)
    }

    /// 改写后段宽可能变化，重新定位再整段选中，下一位数字才敲得进同一段
    private func reselect(_ seg: Segment, in editor: NSTextView) {
        if let again = range(for: seg, in: editor.string as NSString) {
            editor.setSelectedRange(again)
        }
        editor.needsDisplay = true
    }

    /// 键入全程净化（delegate=self）：非法字符剔除、段内位数封顶，
    /// 超出模板的部分直接不落进文本；改写后光标随净化串末尾。
    /// 净化之后再过一遍分段进位：未点选分段时它立即返回（与改造前逐键一致），
    /// 点选了分段则光标回到该段，下一位数字才能整段覆盖着往十位进。
    func controlTextDidChange(_ obj: Notification) {
        guard let editor = currentEditor() as? NSTextView else { return }
        let cleaned = Self.sanitize(editor.string)
        if cleaned != editor.string {
            mutatingText = true
            editor.string = cleaned
            mutatingText = false
            editor.setSelectedRange(NSRange(location: (cleaned as NSString).length, length: 0))
        }
        applySegmentDigit(editor)
    }

    /// 键入净化：剔除 0-9 与分隔符以外的一切字符，且整体必须是模板前缀
    ///（段内位数封顶，超出即截停）；返回净化后的最长合法串
    static func sanitize(_ raw: String) -> String {
        var out = ""
        for ch in raw {
            guard ("0"..."9").contains(ch) || "/-: ".contains(ch) else { continue }
            let next = out + String(ch)
            if inputTemplate.firstMatch(in: next, range: NSRange(next.startIndex..., in: next)) != nil {
                out = next
            } else {
                break   // 当前段已满（如天段已有 2 位）：后续不再放行
            }
        }
        return out
    }

    /// 严格解析：完整 yyyy/M/d H:m；越界值与 2/30 这类不存在的日期直接拒绝，绝不进位滚动
    static func parseDateText(_ text: String) -> Date? {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard let m = commitTemplate.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else {
            return nil
        }
        let ns = s as NSString
        let g = { (i: Int) in Int(ns.substring(with: m.range(at: i))) ?? -1 }
        let (y, mo, d, h, mi) = (g(1), g(2), g(3), g(4), g(5))
        guard mo >= 1, mo <= 12, d >= 1, d <= 31, h <= 23, mi <= 59 else { return nil }
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        guard let parsed = Calendar.current.date(from: c) else { return nil }
        // 防 2/30、2/31 静默进位：组回读必须与输入逐项一致
        let back = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: parsed)
        guard back.year == y, back.month == mo, back.day == d,
              back.hour == h, back.minute == mi else { return nil }
        return parsed
    }

    /// 提交可见文本：成功则生效、补零规范化并回调，失败则标红并保留上一有效值。
    /// 返回 false = 文本非法（保存路径据此拦截，不得拿旧 date 静默落库）
    @discardableResult
    func commit() -> Bool {
        wantsLayer = true
        guard let d = Self.parseDateText(stringValue) else {
            layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.28).cgColor
            return false
        }
        date = d
        layer?.backgroundColor = nil
        // 段内敲出的「9」落成「09」：显示格式与 dateParser 单一口径，不留单数字形态
        let canonical = dateParser.string(from: d)
        if stringValue != canonical { stringValue = canonical }
        onValidChange?(d)
        return true
    }
}

// MARK: - 单条提前提醒设置

final class ReminderTimingView: NSView, NSTextFieldDelegate {
    let daysField = NSTextField(string: "")
    let hoursField = NSTextField(string: "")
    private let previewLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let item: SubItem
    var onValidityChanged: ((Bool) -> Void)?

    var validHours: Int? {
        guard let hours = ReminderTiming.hours(days: daysField.stringValue, hours: hoursField.stringValue),
              ReminderTiming.allowsAlert(item, hours: hours) else { return nil }
        return hours
    }

    init(item: SubItem, hours: Int) {
        self.item = item
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 130))
        let before = NSTextField(labelWithString: "提前")
        let days = NSTextField(labelWithString: "天")
        let hourUnit = NSTextField(labelWithString: "小时")
        before.frame = NSRect(x: 0, y: 97, width: 36, height: 20)
        daysField.frame = NSRect(x: 40, y: 93, width: 64, height: 26)
        days.frame = NSRect(x: 112, y: 97, width: 24, height: 20)
        hoursField.frame = NSRect(x: 142, y: 93, width: 64, height: 26)
        hourUnit.frame = NSRect(x: 214, y: 97, width: 40, height: 20)
        daysField.identifier = NSUserInterfaceItemIdentifier("reminderDaysField")
        hoursField.identifier = NSUserInterfaceItemIdentifier("reminderHoursField")
        daysField.setAccessibilityLabel("提前天数")
        hoursField.setAccessibilityLabel("提前小时数")
        daysField.stringValue = String(hours / 24)
        hoursField.stringValue = String(hours % 24)
        for field in [daysField, hoursField] {
            field.delegate = self
            field.alignment = .center
            field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        }
        let daysBox = Glass.fielded(daysField)
        let hoursBox = Glass.fielded(hoursField)
        daysBox.frame = NSRect(x: 40, y: 93, width: 64, height: 26)
        hoursBox.frame = NSRect(x: 142, y: 93, width: 64, height: 26)
        let reset = NSButton(title: "默认 5 小时", target: self, action: #selector(resetDefault))
        reset.bezelStyle = .glass
        reset.font = .systemFont(ofSize: 11)
        reset.frame = NSRect(x: 258, y: 92, width: 102, height: 28)
        previewLabel.frame = NSRect(x: 0, y: 60, width: 360, height: 22)
        previewLabel.font = .systemFont(ofSize: 12)
        hintLabel.frame = NSRect(x: 0, y: 5, width: 360, height: 46)
        hintLabel.font = .systemFont(ofSize: 11)
        for view in [before, daysBox, days, hoursBox, hourUnit, reset, previewLabel, hintLabel] { addSubview(view) }
        refreshPreview()
    }

    required init?(coder: NSCoder) { fatalError() }

    func controlTextDidChange(_ obj: Notification) { refreshPreview() }
    func controlTextDidEndEditing(_ obj: Notification) { refreshPreview() }

    func showSaveFailure() {
        hintLabel.textColor = .systemRed
        hintLabel.stringValue = "保存失败，原设置保持不变。请重试。"
    }

    @objc private func resetDefault() {
        window?.makeFirstResponder(nil)
        daysField.stringValue = "0"
        hoursField.stringValue = String(ReminderTiming.defaultHours)
        refreshPreview()
    }

    func refreshPreview(now: Date = Date()) {
        guard let hours = validHours else {
            previewLabel.stringValue = "请填写有效的提前时间"
            hintLabel.textColor = .systemRed
            if ReminderTiming.hours(days: daysField.stringValue, hours: hoursField.stringValue) != nil {
                hintLabel.stringValue = "提前时间必须短于该记录的重置周期。"
            } else {
                hintLabel.stringValue = "天数填 0–\(ReminderTiming.maxDays)，小时填 0–23；总计至少 1 小时。"
            }
            onValidityChanged?(false)
            return
        }
        let when = item.expiresAt.addingTimeInterval(-Double(hours) * 3600)
        previewLabel.stringValue = "提醒时刻：\(Fmt.absTime(when))"
        hintLabel.textColor = .secondaryLabelColor
        if item.expiresAt <= now {
            hintLabel.stringValue = "此条已过期；设置会保存，下次调整到期时间后生效。"
        } else if when <= now {
            hintLabel.stringValue = "已进入提醒范围；本轮尚未提醒时，保存后会立即弹窗。"
        } else {
            hintLabel.stringValue = "只修改此条记录，保存后持续生效。"
        }
        onValidityChanged?(true)
    }
}

final class ReminderTimingController: NSWindowController, NSWindowDelegate {
    let editor: ReminderTimingView
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    var onSave: ((Int) -> Bool)?

    init(item: SubItem, hours: Int) {
        editor = ReminderTimingView(item: item, hours: hours)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 280),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        Glass.glassWindow(window)
        window.title = "提前提醒"
        FloatingWindowPolicy.prepareAccessory(window)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = true
        }
        let surface = GlassSurface(frame: NSRect(x: 0, y: 0, width: 400, height: 280))
        surface.cornerRadius = 20
        let content = NSView(frame: surface.bounds)
        content.autoresizingMask = [.width, .height]
        surface.contentView = content
        window.contentView = surface
        let title = NSTextField(labelWithString: "⏳ 提前提醒")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.frame = NSRect(x: 20, y: 236, width: 360, height: 24)
        let name = NSTextField(labelWithString: item.name)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.toolTip = item.name
        name.frame = NSRect(x: 20, y: 211, width: 360, height: 18)
        let expiry = NSTextField(labelWithString: "到期时间：\(Fmt.absTime(item.expiresAt))")
        expiry.font = .systemFont(ofSize: 11)
        expiry.textColor = .secondaryLabelColor
        expiry.frame = NSRect(x: 20, y: 191, width: 360, height: 18)
        editor.frame.origin = NSPoint(x: 20, y: 54)
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .glass
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 224, y: 18, width: 72, height: 30)
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.bezelStyle = .glass
        saveButton.keyEquivalent = "\r"
        saveButton.contentTintColor = .systemBlue
        saveButton.frame = NSRect(x: 306, y: 18, width: 74, height: 30)
        for view in [title, name, expiry, editor, cancel, saveButton] { content.addSubview(view) }
        editor.onValidityChanged = { [weak self] valid in self?.saveButton.isEnabled = valid }
        editor.refreshPreview()
        window.initialFirstResponder = editor.daysField
    }

    required init?(coder: NSCoder) { fatalError() }

    func runModal() -> NSApplication.ModalResponse {
        guard let window else { return .cancel }
        FloatingWindowPolicy.prepareAccessory(window)
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        Motion.present(window)                 // 淡入 + 内容轻微上浮，不是硬弹出来
        defer { Motion.dismissWindow(window) } // 淡出退场
        return NSApp.runModal(for: window)
    }

    @objc private func saveClicked() {
        window?.makeFirstResponder(nil)
        guard let hours = editor.validHours else { editor.refreshPreview(); return }
        guard onSave?(hours) == true else { editor.showSaveFailure(); return }
        NSApp.stopModal(withCode: .OK)
    }

    @objc private func cancelClicked() { NSApp.stopModal(withCode: .cancel) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.stopModal(withCode: .cancel)
        return true
    }
}

// MARK: - 内联编辑卡（悬浮窗内直接调整到期时间）

final class InlineEditView: NSView {
    var onChange: ((Date) -> Void)?
    var onDelete: (() -> Void)?
    var onEditMore: (() -> Void)?
    var onDone: (() -> Void)?

    private let expiryField = DateTextField(date: Date(), identifier: "inlineExpiryField")
    private let statusLabel = NSTextField(labelWithString: "")
    private var statusResetTimer: Timer?

    /// 卡片高度变了（状态行出现/消失）时通知宿主重排。
    /// 不挂这一句，showStatus 撑出的 14pt 没人认领：行高只在 layoutChrome 里读一次，
    /// 结果「保存失败」这类提示会被挤在卡片里裁掉（实测）。
    var onHeightChanged: (() -> Void)?

    /// 卡片内的现有界面反馈（如对齐同步失败），不依赖系统通知
    /// 卡片内的现有界面反馈（不发系统通知/飞书）
    /// autoHide=false：失败类提示持续显示，直到下一次成功写入（clearStatus）或卡片关闭
    func showStatus(_ text: String, color: NSColor, autoHide: Bool = true) {
        statusLabel.stringValue = text
        statusLabel.textColor = color
        statusLabel.isHidden = false
        invalidateIntrinsicContentSize()
        onHeightChanged?()
        Motion.fadeIn(statusLabel)
        statusResetTimer?.invalidate()   // 先取消旧计时器，再按本次语义决定是否隐藏
        statusResetTimer = nil
        guard autoHide else { return }
        statusResetTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            self?.statusLabel.isHidden = true
            self?.invalidateIntrinsicContentSize()
            self?.onHeightChanged?()
        }
    }

    /// 清除状态行（下一次成功写入时调用，解除失败持续提示）
    func clearStatus() {
        statusResetTimer?.invalidate()
        statusResetTimer = nil
        guard !statusLabel.isHidden else { return }
        statusLabel.isHidden = true
        invalidateIntrinsicContentSize()
        onHeightChanged?()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: statusLabel.isHidden ? 98 : 112)
    }

    init(item: SubItem) {
        super.init(frame: .zero)
        wantsLayer = true
        // 编辑卡是一块独立玻璃片：轻微压暗 + 细描边，让卡片在浅色壁纸上也有清晰边界
        let card = Glass.card(cornerRadius: 9)
        card.wantsLayer = true
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // 卡内统一「平贴芯片」语言：深色底 + 细描边，替代 .glass 边框按钮（亮玻璃芯片在暗卡上过跳）。
        // hoverScale=1：卡内只上浮不放大，避免压邻行。圆角由 HoverEffectButton.layout 按高度/2 裁成胶囊。
        func chip(_ title: String, _ action: Selector,
                  textColor: NSColor = NSColor(white: 1, alpha: 0.88),
                  fill: NSColor = NSColor(white: 1, alpha: 0.08)) -> HoverEffectButton {
            let b = HoverEffectButton(title: title, target: self, action: action)
            b.isBordered = false
            b.hoverScale = 1
            b.font = .systemFont(ofSize: 9, weight: .medium)
            b.contentTintColor = textColor
            b.wantsLayer = true
            b.restFill = fill
            b.layer?.borderWidth = 0.5
            b.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
            b.contentPadding = NSEdgeInsets(top: 4, left: 9, bottom: 4, right: 9)
            return b
        }
        func quick(_ title: String, _ seconds: TimeInterval) -> NSButton {
            let b = chip(title, #selector(quick(_:)))
            b.tag = Int(seconds)
            return b
        }
        let quickRow = NSStackView(views: [quick("＋1小时", 3600), quick("＋1天", 86400),
                                           quick("＋1周", 7 * 86400), quick("＋30天", 30 * 86400)])
        quickRow.orientation = .horizontal
        quickRow.spacing = 5
        quickRow.distribution = .fillEqually

        expiryField.setDate(item.expiresAt)
        expiryField.onValidChange = { [weak self] date in
            self?.dateChanged(date)
        }

        let delBtn = chip("删除", #selector(delTapped),
                          textColor: NSColor.systemRed.withAlphaComponent(0.95),
                          fill: NSColor.systemRed.withAlphaComponent(0.12))
        let moreBtn = chip("更多设置…", #selector(moreTapped),
                           textColor: NSColor(white: 1, alpha: 0.66))
        let doneBtn = chip("完成", #selector(doneTapped),
                           textColor: .white,
                           fill: NSColor.controlAccentColor.withAlphaComponent(0.92))
        doneBtn.keyEquivalent = "\r"
        let actRow = NSStackView(views: [delBtn, NSView(), moreBtn, doneBtn])
        actRow.orientation = .horizontal
        actRow.spacing = 8
        actRow.views.first?.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [quickRow, Glass.fielded(expiryField), actRow, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .width   // 快捷芯片/日期框/动作行同宽对齐，消除参差
        stack.spacing = 7
        statusLabel.font = .systemFont(ofSize: 9)
        statusLabel.textColor = .systemRed
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func quick(_ sender: NSButton) {
        expiryField.setDate(expiryField.date.addingTimeInterval(TimeInterval(sender.tag)))
        dateChanged(expiryField.date)
    }

    private func dateChanged(_ date: Date) {
        onChange?(date)
    }

    @objc private func delTapped() { onDelete?() }
    @objc private func moreTapped() { onEditMore?() }
    @objc private func doneTapped() { onDone?() }
}

// MARK: - 添加 / 编辑表单（Sheet，极简）
// 只问「名称(可选) / 到期时间 / 供应商(可选)」；周期、重置模式、伴生重置窗口、命名
// 一律由 Store.saveInferred 在保存时从厂商规则库与同供应商历史自动推断，不再手填。

final class EditorSheetController: NSWindowController {
    /// 保存回调。previousExpiry != nil = 编辑（保留既有重置规则，滚动伴生按到期差值平移）；
    /// weeklyAnchor != nil = 订阅周额度重置（按官方节奏拆第k/n周组）；两者都 nil 时按 kind 走
    /// saveWindow（周期窗口）或 saveInferred（智能推断）。返回 false = 写入失败（表单保持打开）。
    var onSave: ((SubItem, Date?, Date?) -> Bool)?
    /// 返回 true = 已确认删除（此时表单应关闭）；false = 用户取消（表单保持打开）
    var onDelete: ((String) -> Bool)?
    /// 表单关闭回调：保存成功 / 确认删除 / 点取消 / Esc 任一退出路径都会走一次（且仅一次）。
    /// PanelController 用它回收 activeEditors 里的保活引用——以前只在保存成功/删除时移除，
    /// 每次点「取消」就永久泄漏一整棵 430×262 玻璃窗口树（常驻进程越开越肥）。
    var onClose: (() -> Void)?

    /// 自测开关：关闭后保存失败不弹系统弹窗（TestRender 断言表单行为时使用）
    static var showsSaveFailureAlerts = true
    /// 最近一次保存失败的提示文案（含部分失败）；自测断言用
    static var lastSaveFailureMessage: String?

    private var item: SubItem
    private let isNew: Bool
    private let previousExpiry: Date
    /// onClose 一次性闸门：endSheet 会同时命中显式调用与 willClose 通知，只许回调一次
    private var closeNotified = false

    private let nameField = NSTextField(string: "")
    private let vendorCombo = NSComboBox()
    /// 类型档位：0 一次性 / 1 订阅周额度重置 / 2 每周窗口 / 3 每月窗口 / 4 5小时窗口 / 5 2小时窗口 / 6 动态「保持现有」
    private let typePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// 「订阅 · 周额度重置」档的首次重置锚点（官方节奏起点；缺省 = 现在 + 7 天）
    private lazy var firstResetField = DateTextField(date: Date().addingTimeInterval(7 * 86400),
                                                     identifier: "firstResetField")
    private var firstResetRow: NSGridRow?
    private lazy var expiryField = DateTextField(date: item.expiresAt, identifier: "expiryField")
    private let previewLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

    init(item: SubItem, isNew: Bool) {
        self.item = item
        self.isNew = isNew
        self.previousExpiry = item.expiresAt
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 262),
                           styleMask: [.titled],
                           backing: .buffered, defer: false)
        Glass.glassWindow(win)
        win.contentMinSize = NSSize(width: 430, height: 262)
        // 日期行和快捷按钮的固有宽度大约 509。上限只拦「排期文字把窗口拉满屏幕」，
        // 不能卡在 430，否则 layout 一超就会触发断点。
        win.contentMaxSize = NSSize(width: 560, height: 640)
        super.init(window: win)
        buildForm()
        load()
        // 兜底：任何把窗口关掉的路径（含将来直接 close）都要让宿主回收保活引用
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillCloseNote),
                                               name: NSWindow.willCloseNotification, object: win)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func windowWillCloseNote(_ note: Notification) { notifyClosed() }

    /// 关闭通知：一次性，且异步派发。
    /// endSheet 是在 saveClicked/deleteClicked 自己的调用栈里执行的，同步释放宿主保活引用
    /// 会让本控制器在自己的方法尾部 dealloc（按钮 target 还是 weak 引用），风险太高。
    private func notifyClosed() {
        guard !closeNotified else { return }
        closeNotified = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onClose?()
        }
    }

    /// 当前输入组合解析出的供应商（与 Store.saveInferred 同规则，仅用于实时预览）
    private func resolvedVendor() -> String {
        let v = vendorCombo.stringValue.trimmingCharacters(in: .whitespaces)
        if !v.isEmpty { return v }
        return VendorResetKnowledge.vendor(for: nameField.stringValue) ?? "未分类"
    }

    /// 排期日期每行 6 个，避免「 → 」单行固有宽度把 430pt 表单撑满屏幕。
    private static func wrappedArrowList(_ parts: [String], perLine: Int = 6) -> String {
        guard perLine > 0, !parts.isEmpty else { return parts.joined(separator: " → ") }
        var lines: [String] = []
        var index = 0
        while index < parts.count {
            let end = min(index + perLine, parts.count)
            lines.append(parts[index..<end].joined(separator: " → "))
            index = end
        }
        return lines.joined(separator: "\n")
    }

    /// 保存时底层将如何处理（仅预览；真正的写入在 Store.saveInferred / saveWindow / saveWeeklySplit）
    private func updatePreview() {
        firstResetRow?.isHidden = typePopup.indexOfSelectedItem != 1
        switch typePopup.indexOfSelectedItem {
        case 1:
            let span = expiryField.date.timeIntervalSince(firstResetField.date)
            guard span.isFinite else {
                previewLabel.stringValue = "日期超出可表示范围，请重新输入"
                break
            }
            // 与 saveClicked 的锚点守卫同文案：预览报的因和保存拦的因必须一致
            guard span >= 0 else {
                previewLabel.stringValue = "首次重置需早于（或等于）订阅到期"
                break
            }
            guard span < 520 * 7 * 86400 else {
                previewLabel.stringValue = "最多拆分 520 周，请检查首次重置和到期日期"
                break
            }
            let plan = QuotaAdvice.weeklyPlan(expiry: expiryField.date,
                                              firstReset: firstResetField.date)
            let dates = plan.resets.map { Fmt.shortDate($0) }
            let schedule = Self.wrappedArrowList(dates)
            previewLabel.stringValue = "排期共 \(plan.resets.count) 轮：\n\(schedule)"
                + (plan.advice.isEmpty ? "" : "\n" + plan.advice.joined(separator: "\n"))
        case 2:
            previewLabel.stringValue = "周期额度：每 7 天滚动一轮，到期自动滚入下一轮（窗口起点倒推为 到期−7天）"
        case 3:
            previewLabel.stringValue = "周期额度：每 30 天滚动一轮，到期自动滚入下一轮（窗口起点倒推为 到期−30天）"
        case 4:
            previewLabel.stringValue = "周期额度：每 5 小时滚动一轮，到期自动滚入下一轮（窗口起点倒推为 到期−5小时）"
        case 5:
            previewLabel.stringValue = "周期额度：每 2 小时滚动一轮，到期自动滚入下一轮（窗口起点倒推为 到期−2小时，Grok 短窗口适用）"
        case 6:
            previewLabel.stringValue = "周期额度：保持现有周期与重置规则，仅更新名称/供应商/到期时间"
        default:
            previewLabel.stringValue = "只记录到期日，不自动生成额度窗口；需要循环请选择周期额度"

        }
        fitEditorFrame()
    }

    /// 预览折行只许长高。宽度锁死 430，高度夹在 262...520。
    private func fitEditorFrame() {
        guard let view = window?.contentView, let win = window else { return }
        // 先钉死宽度再量高度。fittingSize 在宽度未约束时会按「整段排期不换行」的固有宽度回量，
        // 量出来的高度是单行高，随后 setContentSize 又会把窗口拉宽。
        // 宽度沿用当前值，但夹在 430...560：文字抗压缩已经放低，这里再兜一层，
        // 避免某一轮 layout 按整段排期的固有宽度把窗口拉出屏幕。
        let width = min(max(win.contentView?.bounds.width ?? 430, 430), 560)
        let currentH = max(win.contentView?.bounds.height ?? 262, 262)
        win.setContentSize(NSSize(width: width, height: currentH))
        view.layoutSubtreeIfNeeded()
        let fitted = view.fittingSize.height
        let height = fitted.isFinite ? min(max(fitted, 262), 640) : 262
        win.setContentSize(NSSize(width: width, height: height))
    }

    /// 拆分预览用的名称（与 saveWeeklySplit 命名同源：空名称回退到供应商）
    private func displayName() -> String {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? resolvedVendor() : name
    }

    /// 按条目现状回填类型档位；非标准周期的旧条目动态插入「保持现有」档避免误改
    private func loadTypeSelection() {
        guard item.kind == .window else {
            typePopup.selectItem(at: 0)
            return
        }
        if let rule = item.resetRule, rule != .rolling {
            typePopup.insertItem(withTitle: "周期额度 · 日历锚定（保持现有规则）", at: 6)
            typePopup.selectItem(at: 6)
        } else if let h = item.repeatHours {
            switch h {
            case 5: typePopup.selectItem(at: 4)
            case 2: typePopup.selectItem(at: 5)
            case 720: typePopup.selectItem(at: 3)
            case 168: typePopup.selectItem(at: 2)
            default:
                typePopup.insertItem(withTitle: "周期额度 · 每 \(Int(h)) 小时（保持现有周期）", at: 6)
                typePopup.selectItem(at: 6)
            }
        } else {
            typePopup.selectItem(at: 2)   // 无周期的旧窗口：保存时修复为每周滚动
        }
    }

    private func buildForm() {
        nameField.placeholderString = "可选，留空自动命名"
        nameField.target = self
        nameField.action = #selector(inputChanged)   // 名称影响供应商识别 → 刷新预览
        vendorCombo.addItems(withObjectValues: ["OpenAI", "Anthropic", "xAI", "Google", "中转站", "其他"])
        vendorCombo.completes = true
        vendorCombo.placeholderString = "可选，留空按名称识别"
        vendorCombo.target = self
        vendorCombo.action = #selector(inputChanged)
        typePopup.addItems(withTitles: ["一次性到期", "订阅 · 周额度重置（第k/n周）", "周期额度 · 每周（7天）", "周期额度 · 每月（30天）", "周期额度 · 5小时", "周期额度 · 2小时"])
        typePopup.font = .systemFont(ofSize: 11)
        typePopup.target = self
        typePopup.action = #selector(inputChanged)
        // 首次重置锚点缺省 = 下一轮周重置（现在 + 7 天）；订阅剩余不足 7 天时钳到到期时刻。
        // 早先是「到期 + 7 天」，恒晚于到期 → 直接点选该档不改锚点就无法保存。
        firstResetField.setDate(min(item.expiresAt, Date().addingTimeInterval(7 * 86400)))
        firstResetField.onValidChange = { [weak self] _ in self?.inputChanged() }
        expiryField.setDate(item.expiresAt)
        expiryField.onValidChange = { [weak self] _ in self?.inputChanged() }
        previewLabel.font = .systemFont(ofSize: 9.5)
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.cell?.wraps = true
        previewLabel.cell?.usesSingleLineMode = false
        previewLabel.cell?.lineBreakMode = .byWordWrapping
        previewLabel.maximumNumberOfLines = 16   // 折行后的排期和建议都要看得见
        previewLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewLabel.preferredMaxLayoutWidth = 314   // 430 − 左右 14 − 标签列 80 − 列间距 8
        statusLabel.font = .systemFont(ofSize: 9)
        statusLabel.textColor = .systemRed
        statusLabel.isHidden = true

        func quickBtn(_ title: String, _ seconds: TimeInterval) -> NSButton {
            let b = HoverEffectButton(title: title, target: self, action: #selector(quickSet(_:)))
            b.bezelStyle = .glass
            b.controlSize = .small
            b.tag = Int(seconds)
            return b
        }
        let quickRow = NSStackView(views: [quickBtn("＋1小时", 3600), quickBtn("＋1天", 86400),
                                           quickBtn("＋1周", 7 * 86400), quickBtn("＋30天", 30 * 86400)])
        quickRow.orientation = .horizontal
        quickRow.spacing = 6
        let dateRow = NSStackView(views: [Glass.fielded(expiryField), quickRow])
        dateRow.orientation = .horizontal
        dateRow.spacing = 8

        func label(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: 11)
            return l
        }
        let infoStack = NSStackView(views: [previewLabel, statusLabel])
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 3

        let nameBox = Glass.fielded(nameField)
        let firstResetBox = Glass.fielded(firstResetField)
        let vendorBox = Glass.fielded(vendorCombo)
        let grid = NSGridView(views: [
            [label("名称"), nameBox],
            [label("类型"), typePopup],
            [label("到期时间"), dateRow],
            [label("首次重置"), firstResetBox],
            [label("供应商"), vendorBox],
            [NSView(), infoStack],
        ])
        // 包了玻璃容器就得自己把宽度要回来：NSGridView 只按单元格视图的固有尺寸给宽，
        // 而空内容文本框的固有宽度≈0，容器会塌成内边距那 12pt（实测名称框只剩一个字宽）。
        // 网格总宽由 container 两侧 -14 钉死，所以直接按网格宽减掉标签列。
        for box in [nameBox, firstResetBox, vendorBox] {
            box.widthAnchor.constraint(equalTo: grid.widthAnchor,
                                       constant: -(80 + grid.columnSpacing)).isActive = true
        }
        firstResetRow = grid.row(at: 3)
        firstResetRow?.isHidden = true
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 80
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        // 跟名称框一样钉住列宽，避免排期文字的固有宽度把网格撑开。
        infoStack.widthAnchor.constraint(equalTo: grid.widthAnchor,
                                          constant: -(80 + grid.columnSpacing)).isActive = true
        grid.translatesAutoresizingMaskIntoConstraints = false

        let deleteBtn = HoverEffectButton(title: "删除", target: self, action: #selector(deleteClicked))
        deleteBtn.contentTintColor = .systemRed
        deleteBtn.isHidden = isNew            // 新建无物可删
        let cancelBtn = HoverEffectButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancelBtn.keyEquivalent = "\u{1b}"
        let saveBtn = HoverEffectButton(title: "保存", target: self, action: #selector(saveClicked))
        saveBtn.keyEquivalent = "\r"
        let btnSpacer = NSView()
        btnSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 50), for: .horizontal)
        let btnRow = NSStackView(views: [deleteBtn, btnSpacer, cancelBtn, saveBtn])
        btnRow.orientation = .horizontal
        btnRow.translatesAutoresizingMaskIntoConstraints = false

        let glass = Glass.plate(cornerRadius: 0, tint: Glass.bodyTint)
        glass.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(glass)
        container.addSubview(grid)
        container.addSubview(btnRow)
        window?.contentView = container

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            btnRow.topAnchor.constraint(greaterThanOrEqualTo: grid.bottomAnchor, constant: 12),
            btnRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            btnRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            btnRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
    }

    private func load() {
        nameField.stringValue = item.name
        vendorCombo.stringValue = item.vendor
        expiryField.setDate(item.expiresAt)
        loadTypeSelection()
        updatePreview()
    }

    // 表单极简后任何输入变化都只影响推断预览，共用一个刷新入口；顺带清除过期的错误提示
    @objc private func inputChanged() {
        statusLabel.isHidden = true
        updatePreview()
    }

    /// 快捷按钮始终沿已填写的时间累加
    @objc private func quickSet(_ sender: NSButton) {
        expiryField.setDate(expiryField.date.addingTimeInterval(TimeInterval(sender.tag)))
        updatePreview()
    }

    @objc private func cancelClicked() {
        window?.sheetParent?.endSheet(window!)
        notifyClosed()
    }

    @objc private func deleteClicked() {
        // 仅在真正删除后才关闭表单；用户在确认框点取消时保持表单打开
        if onDelete?(item.id) == true {
            window?.sheetParent?.endSheet(window!)
            notifyClosed()
        }
    }

    @objc private func saveClicked() {
        // 保存以框内可见文本为准：文本非法（越界/不存在/残缺）时先拦下，
        // 否则会把上一有效日期当成本次输入静默写库并关闭表单。
        guard expiryField.commit() else {
            statusLabel.stringValue = "到期时间无效，请按 yyyy-MM-dd HH:mm 重新输入"
            statusLabel.isHidden = false
            return
        }
        var it = item
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        it.name = (isNew || !name.isEmpty) ? name : item.name   // 编辑时清空名称视为不改
        // 供应商留空原样上交：保存管线会按名称识别厂商，表单预览与底层用同一套规则
        it.vendor = vendorCombo.stringValue.trimmingCharacters(in: .whitespaces)
        it.expiresAt = expiryField.date
        it.source = "manual"
        // 类型档位：显式声明优先于推断；「保持现有」档不动周期与重置规则
        var weeklyAnchor: Date?
        switch typePopup.indexOfSelectedItem {
        case 1:
            // 订阅 · 周额度重置：官方节奏自首次重置每 7 天一档，拆「第k/n周」组
            guard firstResetField.commit() else {
                statusLabel.stringValue = "首次重置无效，请按 yyyy-MM-dd HH:mm 重新输入"
                statusLabel.isHidden = false
                return
            }
            let anchor = firstResetField.date
            guard anchor <= it.expiresAt else {
                statusLabel.stringValue = "首次重置需早于（或等于）订阅到期"
                statusLabel.isHidden = false
                return
            }
            if !isNew, item.groupID != nil {
                statusLabel.stringValue = "该条目已属周额度组：请直接编辑单条，或删除整组后重新添加"
                statusLabel.isHidden = false
                return
            }
            weeklyAnchor = anchor
        case 2, 3, 4, 5:
            it.kind = .window
            it.repeatHours = [168.0, 720.0, 5.0, 2.0][typePopup.indexOfSelectedItem - 2]
            it.resetRule = .rolling
            it.resetParam = it.repeatHours!.truncatingRemainder(dividingBy: 24) == 0
                ? Int(it.repeatHours! / 24) : nil
            if let h = it.repeatHours {
                it.purchaseAt = it.expiresAt.addingTimeInterval(-h * 3600)   // 倒推窗口起点
                it.note = h >= 24
                    ? "周期额度：每 \(Int(h / 24)) 天滚动一轮，到期自动顺延"
                    : "周期额度：每 \(Int(h)) 小时滚动一轮，到期自动顺延"
            }
            // 转成独立周期窗口：摘掉周额度组的残留（见 detachLegacyGroupFields）
            Self.detachLegacyGroupFields(&it)
        case 6:
            if let h = it.repeatHours {
                it.purchaseAt = it.expiresAt.addingTimeInterval(-h * 3600)   // 倒推窗口起点
            }
        default:
            it.kind = .subscription
            it.repeatHours = nil
            it.resetRule = nil
            it.resetParam = nil
            it.purchaseAt = nil          // 一次性不保留「窗口起点」，否则推断/进度仍按旧周期算
            it.note = "一次性到期提醒：到期不自动生成额度窗口。"
            // 转成一次性：摘掉组 ID、组序号后缀与额度徽标（见 detachLegacyGroupFields）
            Self.detachLegacyGroupFields(&it)
        }

        // 归档条目被改到未来 = 用户重新启用它：必须清 archivedAt。
        // Store.purgeArchived 只看 archivedAt 距今是否超 30 天，全仓又没有任何「取消归档」路径，
        // 不清的话这条改到未来的条目会在下一次心跳被当成过期归档清除掉。
        if it.archivedAt != nil, it.expiresAt > Date() { it.archivedAt = nil }

        Self.lastSaveFailureMessage = nil
        let saved = onSave?(it, isNew ? nil : previousExpiry, weeklyAnchor) ?? false
        guard saved else {
            // 写入失败：表单保持打开、输入原样保留，用户可直接重试
            Self.lastSaveFailureMessage = "保存失败"
            statusLabel.stringValue = "保存失败，请重试"
            statusLabel.isHidden = false
            if Self.showsSaveFailureAlerts {
                let alert = NSAlert()
                alert.messageText = "保存失败"
                alert.informativeText = "数据未能写入，表单内容已保留，请重试。"
                FloatingWindowPolicy.runAlert(alert)
            }
            return
        }
        // 鼠标点保存已在 HoverEffectButton.mouseDown 出声；回车走 keyEquivalent，这里补一次
        if NSApp.currentEvent?.type == .keyDown {
            Motion.playTap()
        }
        window?.sheetParent?.endSheet(window!)
        notifyClosed()
        if let msg = Self.lastSaveFailureMessage, Self.showsSaveFailureAlerts {
            let alert = NSAlert()
            alert.messageText = "部分保存失败"
            alert.informativeText = msg
            FloatingWindowPolicy.runAlert(alert)
        }
    }

    /// 切换类型档位时摘掉「周额度组」的残留字段。
    /// 「·第k/n周」是 saveWeeklySplit 的命名后缀，同组条目共用一个 groupID：
    /// 条目转成一次性 / 独立周期窗口后若不清 groupID，设置后台「删除整组」会按
    /// group_id 把这条已经独立的条目连带删掉（数据丢失）；usedPercent 不清则行上
    /// 长期挂着「已用 60% · ⚡消耗节奏」的额度徽标，与一次性语义矛盾。
    private static func detachLegacyGroupFields(_ it: inout SubItem) {
        it.groupID = nil
        it.usedPercent = nil
        if let r = it.name.range(of: "·第[0-9]+/[0-9]+周$", options: .regularExpression) {
            it.name = String(it.name[..<r.lowerBound])
        }
    }
}

// MARK: - 悬浮窗控制器
// 平时贴右侧吸附为一个迷你药丸，点击展开为紧凑玻璃面板，鼠标离开 8 秒后自动收起。

final class PanelController: NSObject, NSMenuDelegate {
    private enum Metrics {
        static let expandedWidth: CGFloat = 240
        static let pillWidth: CGFloat = 54
        static let pillHeight: CGFloat = 18
        static let dockMargin: CGFloat = 6
        static let headerH: CGFloat = 16
        static let rowH: CGFloat = 28
        static let sectionH: CGFloat = 14
        static let spacing: CGFloat = 1
        static let padSide: CGFloat = 8
        static let padTop: CGFloat = 5
        static let padBottom: CGFloat = 5
        static let pillFontSize: CGFloat = 9
        static let pillMinFontSize: CGFloat = 6.5
        /// 展开面板高度封顶：内容再长也只占可视区，行区转入滚动
        static let minViewportH: CGFloat = 180
        static let screenMargin: CGFloat = 8
        static let scrollIndicatorW: CGFloat = 3
        /// 非精密滚轮（普通鼠标）一格 ≈ 一行
        static let wheelLineStep: CGFloat = 24
    }

    private let panel: FloatingPanel
    private let effect = GlassSurface()
    private let titleLabel = NSTextField(labelWithString: "⏳")
    private let rowsClip = RowsClipView()
    private let rowsContainer = NSView()
    private let scrollIndicator = NSView()
    private let pillLabel = NSTextField(labelWithString: "")
    private let pillHoverOutline = PillHoverOutline()
    private let headerView = NSStackView()
    private let controls = CapsuleControlsView()
    private var controlsVisible = false
    /// 控制区的布局可见性真源：淡出完成后才置 true，layoutChrome 只认它，
    /// 不直接读 controlsVisible —— 否则淡出动画会被逐帧 layout 抢先打断。
    private var controlsHidden = true
    /// 上一次渲染的收起/展开态（nil = 尚未渲染过）：只在状态翻转时播过渡，
    /// 窗口尺寸动画期间的逐帧 layout 不会重播。
    private var renderedCollapsed: Bool?
    /// 滚动指示条当前是否应显示：只有翻转时才播淡入淡出
    private var scrollIndicatorShown: Bool?
    private var controlsButton: NSButton!

    /// 行区滚动状态：rowsContentH 是全部行的自然总高，viewportH 是窗口限高后的可视高度
    private var rowsContentH: CGFloat = 0
    private var viewportH: CGFloat = 0
    private var scrollOffset: CGFloat = 0
    /// 展开被整体上移（药丸位置太低）时记录药丸原顶边，收起时回位；拖动面板即作废
    private var expandAnchorTopY: CGFloat?
    private var liftedTopY: CGFloat?

    private var currentIds: [String] = []
    private var refreshButton: NSButton!
    private var editingId: String?
    private var renderedEditingId: String?
    private weak var activeInlineView: InlineEditView?
    private var autoItems: [SubItem] = []
    private var refreshing = false
    private var hiddenByUser = false
    private var menuTrackingDepth = 0
    private var tickCount = 0
    /// deadline 驱动的窗口滚动：只有跨过下一个重置节点才碰 Store，杜绝每秒空转遍历
    private var rollDeadline: Date = .distantPast   // 启动首次 tick 必滚（补睡眠/离线期间）
    /// dataVersion 驱动的重建：条目集合没变就不重排、不重建
    private var lastSeenDataVersion = -1
    /// 上次按展示窗口过滤后的可见 id（排序）。dataVersion 不变时，跨过窗口边界也要靠它重建。
    private var lastHorizonIDs: [String] = []
    /// 上次写进空文案 / tooltip 的 displayHorizonDays。只改天数、可见 id 不变时也要重建，否则天数停在旧数字。
    private var lastHorizonDays: Int?
    /// 已弹过临期弹窗的条目（id@到期瞬间）：同一到期只弹一次，重启后可能再弹一次。
    private var alertedKeys = Set<String>()
    /// 模态期间攒下的临期条目：不叠第二个模态弹窗，等空闲心跳再补弹
    private var pendingCritical: [SubItem] = []
    /// 自己 setFrame 期间为 true：didMove 通知在同一调用栈里打进 moved()，
    /// 不挡住就会把展开态 origin 写进 panelOrigin、并把上移展开的记账清零。
    private var programmaticMove = false
    /// withCollapseSuppressed 的嵌套层数：月历/编辑卡里再弹确认框会套娃，
    /// 只有最外层结束才允许恢复自动收起节奏。
    private var suppressDepth = 0
    private var statusItem: NSStatusItem?
    /// 菜单栏图标下的那份菜单；只为在每次展开前重读常驻勾选态
    private var statusMenu: NSMenu?
    private var menuBarRestorePending = false
    private weak var statusLaunchItem: NSMenuItem?
    private var settings: SettingsWindowController?
    private var activeEditors: [EditorSheetController] = []
    private var collapseTimer: Timer?
    private var collapseSuppressor = AutoCollapseSuppressor()
    private var container: PanelContainerView!

    init(loadOfficialData: Bool = true) {
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: Metrics.pillWidth, height: Metrics.pillHeight),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        super.init()
        setupPanel()
        buildUI()
        buildStatusItem()
        rebuildAll()
        // 月历浮在面板之上：打开期间拦住 8 秒自动收起，否则面板一收日历就成孤儿
        CalendarPickerController.shared.onOpenChanged = { [weak self] open in
            guard let self = self else { return }
            if open {
                self.beginInteraction()
            } else { self.endInteraction() }
        }
        // 与刚搭好的空文案对齐，避免首次心跳把「还没记过」当成天数变化而全量重建。
        lastHorizonDays = Store.shared.displayHorizonDays
        if loadOfficialData { refreshData() }
    }

    // MARK: 面板与位置

    private func setupPanel() {
        panel.level = FloatingWindowPolicy.panelLevel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.canHide = false
        // 常驻面板只 orderOut，永远不该被 close 释放；显式置 false 防将来
        // 任何一条 close() 路径把窗口释放掉（NSWindow 默认 isReleasedWhenClosed = true）。
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = FloatingWindowPolicy.spaces
        panel.appearance = NSAppearance(named: .darkAqua)

        let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        if let f = screen?.visibleFrame {
            panel.setFrame(NSRect(x: f.maxX - Metrics.dockMargin - Metrics.pillWidth,
                                  y: f.maxY - Metrics.screenMargin - Metrics.pillHeight,
                                  width: Metrics.pillWidth, height: Metrics.pillHeight),
                           display: false)
        }

        // 恢复上次位置：必须落在现存屏幕的可见范围内（显示器拔插/换排列后自动回位）
        if let xy = UserDefaults.standard.array(forKey: "panelOrigin") as? [Double], xy.count == 2 {
            let p = NSPoint(x: xy[0], y: xy[1])
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -8, dy: -8).contains(p) }) {
                panel.setFrameOrigin(p)
            } else {
                UserDefaults.standard.removeObject(forKey: "panelOrigin")
            }
        }

        NotificationCenter.default.addObserver(self, selector: #selector(moved),
                                               name: NSWindow.didMoveNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(restorePresentation),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(restorePresentation),
                                                              name: name, object: nil)
        }
    }

    private func buildUI() {
        effect.cornerRadius = 18

        titleLabel.font = .systemFont(ofSize: 10)

        func miniBtn(_ title: String, _ action: Selector) -> NSButton {
            let b = HoverEffectButton(title: title, target: self, action: action)
            b.isBordered = false
            b.font = .systemFont(ofSize: 11)
            b.contentTintColor = .secondaryLabelColor
            return b
        }
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 50), for: .horizontal)
        headerView.orientation = .horizontal
        headerView.alignment = .centerY
        headerView.spacing = 6
        headerView.addArrangedSubview(titleLabel)
        headerView.addArrangedSubview(headerSpacer)
        headerView.addArrangedSubview(miniBtn("＋", #selector(addClicked)))
        refreshButton = miniBtn("⟳", #selector(refreshClicked))
        headerView.addArrangedSubview(refreshButton)
        controlsButton = miniBtn("⚙", #selector(toggleControls))
        controlsButton.toolTip = "展开或收起胶囊控制区"
        controlsButton.setAccessibilityLabel("胶囊控制")
        controlsButton.setAccessibilityIdentifier("capsuleControlsToggle")
        headerView.addArrangedSubview(controlsButton)
        let collapseButton = miniBtn("⌃", #selector(collapseClicked))
        collapseButton.toolTip = "收起为倒计时胶囊"
        collapseButton.setAccessibilityLabel("收起悬浮窗")
        headerView.addArrangedSubview(collapseButton)

        pillLabel.font = .monospacedDigitSystemFont(ofSize: Metrics.pillFontSize, weight: .semibold)
        pillLabel.alignment = .center
        pillLabel.lineBreakMode = .byClipping
        pillLabel.maximumNumberOfLines = 1
        pillLabel.textColor = .white
        pillLabel.setAccessibilityIdentifier("capsuleCountdown")


        container = PanelContainerView()
        container.addSubview(headerView)
        container.addSubview(controls)
        controls.moreMenu.delegate = self
        controls.onCollapse = { [weak self] in self?.applyCollapsed(true) }
        controls.onRestore = { [weak self] in self?.restoreToTopRight() }
        controls.onRestoreMenuBar = { [weak self] in self?.restoreMenuBarItem() }
        controls.onHide = { [weak self] in self?.hideClicked() }
        controls.onSettings = { [weak self] in self?.openSettingsWindow() }
        controls.onAutoCollapse = { [weak self] enabled in
            Store.shared.state.panelAutoCollapse = enabled
            Store.shared.save()
            self?.resyncPointerState()
        }
        rowsClip.wantsLayer = true
        rowsClip.layer?.masksToBounds = true
        rowsClip.addSubview(rowsContainer)
        scrollIndicator.wantsLayer = true
        scrollIndicator.layer?.backgroundColor = NSColor(white: 1, alpha: 0.30).cgColor
        scrollIndicator.layer?.cornerRadius = Metrics.scrollIndicatorW / 2
        scrollIndicator.isHidden = true
        rowsClip.addSubview(scrollIndicator)
        rowsClip.onScroll = { [weak self] dy in self?.applyScroll(deltaY: dy) }
        container.addSubview(rowsClip)
        container.addSubview(pillLabel)
        pillHoverOutline.alphaValue = 0
        container.addSubview(pillHoverOutline)
        container.autoresizingMask = [.width, .height]
        effect.contentView = container
        panel.contentView = effect

        container.onMouseEnter = { [weak self] in self?.resyncPointerState() }
        container.onMouseExit = { [weak self] in self?.resyncPointerState() }
        container.onBackgroundClick = { [weak self] in self?.pillClicked() }

        // 右键菜单挂在玻璃 contentView 上，与胶囊点击、行交互共用真正接收事件的容器。
        container.menu = buildContextMenu()

        // 窗口尺寸动画（胶囊↔面板、控制区展开）每一步真实 resize 都会发这条通知，
        // 手动布局靠它逐帧跟上窗口边界——没有它内容会停在最终布局等窗口追上来。
        // 此处必须晚于 container 赋值注册：layoutChrome 依赖它。
        NotificationCenter.default.addObserver(self, selector: #selector(panelDidResize),
                                               name: NSWindow.didResizeNotification, object: panel)
    }

    @objc private func panelDidResize() { layoutChrome() }

    private func setPillHover(_ hovered: Bool) {
        let alpha: CGFloat = hovered ? 1 : 0
        if !Motion.enabled || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            pillHoverOutline.alphaValue = alpha
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                pillHoverOutline.animator().alphaValue = alpha
            }
        }
    }

    /// 月历浮层锚着宿主控件，宿主一动/一改尺寸它就会自毁（observeHost 的设计约定）。
    /// 因此宿主锚定月历期间 frame 落位必须瞬时完成——不能让 0.3s 的逐帧 resize
    /// 把刚弹出的月历连环关掉。
    private var frameAnimationDuration: TimeInterval {
        CalendarPickerController.shared.isVisible ? 0 : 0.3
    }

    /// 以「右上角」为锚点调整窗口尺寸并手动布局。
    /// 展开高度超过「顶边到 Dock 的可用空间」时就地限高（行区转入滚动）；药丸被拖得很低、
    /// 下方放不下最小可用高度时整体向上展开；收起永远回到药丸自己的顶边。
    /// 锚点永远是窗口自己的右缘：用户拖到哪儿就停在哪儿，展开只向左/向下生长。
    /// （旧实现展开时改用 visibleFrame.maxX，中部拖放的药丸一点就跳到屏幕右缘。）
    private func updateFrame(expanded: Bool, contentH: CGFloat) {
        let prev = panel.frame
        var topY = min(prev.maxY, (panel.screen ?? NSScreen.main)?.visibleFrame.maxY ?? prev.maxY)
        let width = expanded ? Metrics.expandedWidth : Metrics.pillWidth
        var height = expanded ? contentH : Metrics.pillHeight
        if expanded, let vis = (panel.screen ?? NSScreen.main)?.visibleFrame {
            if prev.height <= Metrics.pillHeight + 0.5 {
                expandAnchorTopY = topY   // 从药丸态展开：记住药丸顶边
            }
            let availDown = topY - vis.minY - Metrics.screenMargin
            if contentH > availDown {
                let usableMin = min(Metrics.minViewportH, vis.height - Metrics.screenMargin * 2)
                if availDown >= usableMin {
                    height = availDown   // 就地限高，底部不越过 Dock
                } else {
                    // 下方放不下最小可用高度：顶边上移，向上展开
                    height = min(contentH, vis.height - Metrics.screenMargin * 2)
                    topY = vis.minY + height + Metrics.screenMargin
                    liftedTopY = topY
                }
            }
        }
        if !expanded {
            if let lifted = liftedTopY,
               prev.height > Metrics.pillHeight + 0.5,
               abs(prev.maxY - lifted) < 0.5 {
                topY = expandAnchorTopY ?? lifted   // 从上移过的展开态收起：回到药丸原位
            }
            liftedTopY = nil
            expandAnchorTopY = nil
        }
        var anchorRight = prev.maxX
        if let vis = (panel.screen ?? NSScreen.main)?.visibleFrame {
            anchorRight = min(anchorRight, vis.maxX)
            anchorRight = max(anchorRight, vis.minX + width)
        }
        if !expanded, let vis = (panel.screen ?? NSScreen.main)?.visibleFrame {
            topY = min(max(topY, vis.minY + height), vis.maxY)
        }
        // 自己的位移不是用户的位移：setFrame 会在同一调用栈里同步触发 didMove → moved()，
        // 不立这块牌子 moved() 就会把展开记账清零 + 写坏持久化位置。
        // 动画时 didMove 延迟到每步/结束时才发，programmaticMove 挂到动画完成才复位。
        // 尺寸与位置变化全部走窗口动画：胶囊↔面板是平滑形变，不再是硬切。
        let targetOrigin = NSPoint(x: anchorRight - width, y: topY - height)
        programmaticMove = true
        Motion.animateWindowFrame(panel,
                                  to: NSRect(origin: targetOrigin, size: NSSize(width: width, height: height)),
                                  duration: frameAnimationDuration) { [weak self] in self?.programmaticMove = false }
        // 收起落位后才记账位置：moved() 现在只认胶囊态，展开态 origin 一律不写 UserDefaults
        // （写了会让收起后回不到药丸原位、重启后胶囊偏移）。
        // 动画期间 panel.frame 可能还是起点，这里必须写计算出的目标值。
        if !expanded {
            UserDefaults.standard.set([Double(targetOrigin.x), Double(targetOrigin.y)], forKey: "panelOrigin")
        }
        layoutChrome()
        resyncPointerState()
    }

    /// 悬停与自动收起的唯一裁决点：以光标真实位置为准。
    /// resize 会让 AppKit 移除旧追踪区并补发一次假的 mouseExited（且不会为已在内部的指针
    /// 补发 mouseEntered），只信事件就会「面板在鼠标底下 8 秒收起」或「永远收不起」。
    /// - Parameter rearmExistingTimer: false 用于心跳兜底——scheduleAutoCollapse 起手会
    ///   cancel，每秒重挂等于把 8 秒触发无限推迟；光标回到面板内仍要立刻取消。
    private func resyncPointerState(rearmExistingTimer: Bool = true) {
        let inside = isCursorInsidePanel()
        if inside {
            cancelAutoCollapse()
        } else if rearmExistingTimer || collapseTimer == nil {
            scheduleAutoCollapse()
        }
        if Store.shared.state.panelCollapsed { setPillHover(inside) }
    }

    /// 心跳兜底：窗口从静止光标底下被搬走时 AppKit 一个 enter/exit 都不发，
    /// 没有这一步面板会永远卡在展开态。
    private func heartbeatPointerResync() {
        guard panel.isVisible else { return }
        resyncPointerState(rearmExistingTimer: false)
    }

    private func layoutChrome() {
        guard let b = panel.contentView?.bounds else { return }
        let collapsed = Store.shared.state.panelCollapsed
        container.setAccessibilityElement(collapsed)
        container.setAccessibilityRole(collapsed ? .button : .group)
        container.setAccessibilityLabel(collapsed ? "到期提醒，\(pillText())，点击展开" : nil)
        pillLabel.setAccessibilityElement(false)
        pillHoverOutline.frame = b
        pillHoverOutline.isHidden = !collapsed
        if !collapsed { pillHoverOutline.alphaValue = 0 }
        effect.frame = b
        container.frame = b
        effect.cornerRadius = collapsed ? Metrics.pillHeight / 2 : 18
        // 收起/展开共用同一着色：两种状态间不允许出现「液态→磨砂」的质感跳变（用户实测截图）。
        // 绿字在纯白页面上的对比度由玻璃折射本身兜底，实测 α0.60 可读。
        effect.tint = Glass.bodyTint
        effect.needsDisplay = true

        if collapsed {
            pillLabel.isHidden = false
            pillLabel.stringValue = pillText()
            pillLabel.toolTip = horizonTooltip(for: visibleItems) + "\n点击展开 · 拖动移动"
            refitPill()
            if renderedCollapsed != true {
                let firstLayout = (renderedCollapsed == nil)
                renderedCollapsed = true
                transitionToCollapsed(instant: firstLayout || !Motion.canAnimate)
            }
        } else {
            if renderedCollapsed != false {
                let firstLayout = (renderedCollapsed == nil)
                renderedCollapsed = false
                transitionToExpanded(instant: firstLayout || !Motion.canAnimate)
            }
            // 可见性由过渡函数管理，这里只做几何布局；控制区只认 controlsHidden
            controls.isHidden = controlsHidden
            controlsButton.contentTintColor = controlsVisible ? .white : .secondaryLabelColor
            controls.refresh()
            headerView.frame = NSRect(x: Metrics.padSide,
                                      y: b.height - Metrics.padTop - Metrics.headerH,
                                      width: b.width - Metrics.padSide * 2,
                                      height: Metrics.headerH)
            let rowsTop = b.height - Metrics.padTop - Metrics.headerH - 3
            let w = b.width - Metrics.padSide * 2
            let controlsH = controlsVisible ? CapsuleControlsView.height + 4 : 0
            controls.frame = NSRect(x: Metrics.padSide, y: Metrics.padBottom,
                                    width: w, height: CapsuleControlsView.height)
            controls.needsLayout = true
            viewportH = max(rowsTop - Metrics.padBottom - controlsH, 0)
            rowsClip.frame = NSRect(x: Metrics.padSide, y: Metrics.padBottom + controlsH,
                                    width: w, height: viewportH)
            // 行容器装全部内容并随 scrollOffset 平移，超出视口的部分由 rowsClip 的 layer 裁掉。
            // 行自上而下摆在高 y 区（AppKit y 向上）：offset=0 时容器顶对齐视口顶，
            // offset=max 时容器底对齐视口底。
            let maxOffset = max(0, rowsContentH - viewportH)
            scrollOffset = min(max(scrollOffset, 0), maxOffset)
            rowsContainer.frame = NSRect(x: 0, y: scrollOffset - maxOffset,
                                         width: w, height: max(rowsContentH, viewportH))
            // 逐条摆放（自上而下）：分区标题 14 / 行 28 / 内联编辑卡用固有高度，间距 1
            var y = rowsContainer.bounds.height
            for v in rowsContainer.subviews {
                let h = Self.entryHeight(v, rowH: Metrics.rowH, sectionH: Metrics.sectionH)
                y -= h
                v.frame = NSRect(x: 0, y: y, width: w, height: h)
                y -= Metrics.spacing
            }
            layoutScrollIndicator(width: w, viewport: viewportH, content: rowsContentH)
        }
    }

    // MARK: 收起 / 展开过渡（交叉淡入淡出，配合窗口尺寸动画）

    /// 收起：内容随窗口收缩淡出后藏起，胶囊字淡入。
    /// hide 用 completion 由这里决定是否真藏——期间用户再展开时不能把新内容藏掉。
    private func transitionToCollapsed(instant: Bool) {
        func fadeAway(_ view: NSView) {
            if instant {
                view.isHidden = true
                view.alphaValue = 1
            } else {
                Motion.fadeOut(view, duration: 0.16) { [weak self, weak view] in
                    guard let self, let view else { return }
                    if self.renderedCollapsed == true { view.isHidden = true }
                    view.alphaValue = 1   // 恢复 alpha，下次展开直接可用
                }
            }
        }
        fadeAway(rowsClip)
        fadeAway(headerView)
        if !controlsHidden {
            fadeAway(controls)
            controlsHidden = true
        }
        if instant {
            pillLabel.alphaValue = 1
        } else {
            pillLabel.alphaValue = 0
            Motion.fadeIn(pillLabel, duration: 0.2, delay: 0.05)
        }
    }

    /// 展开：胶囊字快速淡出后藏起，列表内容随窗口生长渐入。
    private func transitionToExpanded(instant: Bool) {
        if instant {
            pillLabel.isHidden = true
            pillLabel.alphaValue = 1
        } else {
            Motion.fadeOut(pillLabel, duration: 0.1) { [weak self] in
                guard let self else { return }
                if self.renderedCollapsed == false { self.pillLabel.isHidden = true }
                self.pillLabel.alphaValue = 1
            }
        }
        rowsClip.isHidden = false
        headerView.isHidden = false
        controls.isHidden = controlsHidden
        headerView.alphaValue = 1
        if instant {
            rowsClip.alphaValue = 1
        } else {
            rowsClip.alphaValue = Motion.startAlpha
            Motion.reveal(rowsClip)
        }
    }

    /// 控制区显隐（唯一出口）：显示 = 升起淡入；隐藏 = 淡出完成才真正藏起。
    private func setControlsShown(_ shown: Bool) {
        controlsVisible = shown
        if shown {
            controlsHidden = false
            controls.isHidden = false
            if Motion.canAnimate {
                Motion.slideIn(controls, dy: 8, duration: 0.26)
            } else {
                controls.alphaValue = 1
            }
        } else {
            Motion.fadeOut(controls, duration: 0.14) { [weak self] in
                guard let self else { return }
                if !self.controlsVisible {
                    self.controlsHidden = true
                    self.controls.isHidden = true
                }
                self.controls.alphaValue = 1
            }
        }
    }

    /// 行区子视图的摆位高度：分区标题 / 内联编辑卡（固有高）/ 其余按行高。
    /// layoutChrome 的摆位与 rowsContentH 的记账必须走同一个函数，否则两侧口径会漂移。
    private static func entryHeight(_ v: NSView, rowH: CGFloat, sectionH: CGFloat) -> CGFloat {
        if v is SectionHeaderView { return sectionH }
        if let inline = v as? InlineEditView { return inline.intrinsicContentSize.height }
        return rowH
    }

    /// 内联卡高度变了（showStatus 让卡 98 → 112）：重算行区总高再布局。
    /// 只调 layoutChrome 不够——rowsContentH 不重算，滚到底时多出来的 14pt 没人认领，
    /// 「保存失败」提示被裁在卡片外（实测）。重排走隐式动画：卡与邻行是平滑让位，不是硬跳。
    private func rowsContentSizeChanged() {
        rowsContentH = rowsContainer.subviews
            .reduce(CGFloat(0)) { $0 + Self.entryHeight($1, rowH: Metrics.rowH, sectionH: Metrics.sectionH) + Metrics.spacing }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            self.layoutChrome()
        }
    }

    // MARK: 行区滚动

    private func applyScroll(deltaY: CGFloat) {
        let maxOffset = max(0, rowsContentH - viewportH)
        guard maxOffset > 0, Store.shared.state.panelCollapsed == false else { return }
        let step: CGFloat = abs(deltaY) < 1 ? deltaY * Metrics.wheelLineStep : deltaY   // 精密触控板按像素，普通滚轮按行
        let target = min(max(scrollOffset - step, 0), maxOffset)
        guard target != scrollOffset else { return }
        scrollOffset = target
        // 行容器平移走隐式动画：滚轮内容是滑过去的，不是一格一格硬跳。
        // 模型值立即落位，连续滚动时每格事件都从当前位置追向新目标，天然连贯。
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            self.layoutChrome()
        }
    }

    /// 滚动位置指示条：有溢出才显示，拇指长度与位置按可视比例。显隐走淡入淡出，
    /// 且只在翻转时播一次（逐帧 layout 重复进入不会重启动画）。
    private func layoutScrollIndicator(width: CGFloat, viewport: CGFloat, content: CGFloat) {
        let overflow = content - viewport
        let shouldShow = overflow > 1 && viewport > 12
        if scrollIndicatorShown != shouldShow {
            scrollIndicatorShown = shouldShow
            if shouldShow {
                scrollIndicator.isHidden = false
                if Motion.canAnimate {
                    scrollIndicator.alphaValue = 0
                    Motion.fadeIn(scrollIndicator, duration: 0.18)
                } else {
                    scrollIndicator.alphaValue = 1
                }
            } else {
                let finish = { [weak self] in
                    guard let self, self.scrollIndicatorShown == false else { return }
                    self.scrollIndicator.isHidden = true
                    self.scrollIndicator.alphaValue = 1
                }
                if Motion.canAnimate {
                    Motion.fadeOut(scrollIndicator, duration: 0.18, completion: finish)
                } else {
                    finish()
                }
            }
        }
        guard shouldShow else { return }
        let trackH = viewport - 6
        let thumbH = max(trackH * viewport / content, 28)
        let progress = scrollOffset / overflow
        scrollIndicator.frame = NSRect(x: width - Metrics.scrollIndicatorW - 1,
                                       y: 3 + (trackH - thumbH) * progress,
                                       width: Metrics.scrollIndicatorW,
                                       height: thumbH)
    }

    private func pillText() -> String {
        let now = Date()
        // 没有可见条目时保持「暂无记录」。不许回落到 allItems，展示窗口外的倒计时进不了 54pt 药丸。
        guard let nearest = Self.upcomingFirst(visibleItems, now: now).first else {
            pillLabel.textColor = .secondaryLabelColor
            return "暂无记录"
        }
        pillLabel.textColor = RowView.urgencyColor(nearest, now: now)
        return Fmt.countdownShort(until: nearest.expiresAt, now: now)
    }

    /// 胶囊 / 菜单栏标题 / tooltip 共用的「最近到期」口径：
    /// 优先看还没到期的一批（升序），全部已过期才回落展示过期条目。
    /// 旧口径直接取全局最早那条，而官方条目永不自愈归档
    /// （archiveExpiredSubscriptions 只归档 source=="manual" && kind==.subscription），
    /// 于是 54×18 的胶囊被一条过期官方条目长期钉成灰字「已过期」，后面的到期项一概看不见。
    static func upcomingFirst(_ items: [SubItem], now: Date) -> [SubItem] {
        let sorted = items.sorted { $0.expiresAt < $1.expiresAt }
        let live = sorted.filter { $0.expiresAt > now }
        return live.isEmpty ? sorted : live
    }

    /// 保持原来 54×18 的胶囊尺寸；文字占完整内宽，长倒计时适配字号。
    /// 不使用 sizeToFit 改变框架，也不对每次数字刷新执行位置或透明度动画。
    private func refitPill() {
        let b = container.bounds
        let available = b.width - 12
        var size = Metrics.pillFontSize
        while true {
            pillLabel.font = .monospacedDigitSystemFont(ofSize: size, weight: .medium)
            pillLabel.invalidateIntrinsicContentSize()
            // NSTextField 的 intrinsic 宽度会受当前截断框影响；用完整原文度量并留 cell 内边距。
            let textWidth = (pillLabel.stringValue as NSString).size(withAttributes: [.font: pillLabel.font!]).width
            if ceil(textWidth) + 6 <= available || size <= Metrics.pillMinFontSize { break }
            size -= 0.5
        }
        pillLabel.alphaValue = 1
        pillLabel.frame = NSRect(x: 6, y: (b.height - 14) / 2, width: available, height: 14)
    }

    // MARK: 收起 / 展开

    func applyCollapsed(_ collapsed: Bool) {
        if collapsed { controlsVisible = false }
        Store.shared.state.panelCollapsed = collapsed
        Store.shared.save()
        if !collapsed { scrollOffset = 0 }   // 每次展开都从顶部开始
        rebuildAll()
        // 展开时的内容渐入由 layoutChrome 的 transitionToExpanded 负责（随窗口生长一起淡入）
    }

    func pillClicked() {
        guard Store.shared.state.panelCollapsed else { return }
        applyCollapsed(false)
        cancelAutoCollapse()
    }

    @objc private func collapseClicked() {
        applyCollapsed(true)
    }

    private func scheduleAutoCollapse() {
        cancelAutoCollapse()
        guard Store.shared.state.panelAutoCollapse else { return }
        guard collapseSuppressor.shouldSchedule else { return }   // 说明弹窗/编辑期间抑制
        // 内联编辑卡开着：不挂 8 秒表。放在这个唯一入口而不是各处 begin/end，
        // 是因为卡片有 4 条关闭路径（完成/再点一次/行内删除/条目被刷新抹掉），
        // 漏一条就把抑制状态永久挂住、面板再也收不起来。
        // 卡片关掉后由 heartbeatPointerResync 在下一次心跳（≤1 秒）补挂定时器。
        guard editingId == nil else { return }
        guard !Store.shared.state.panelCollapsed else { return }
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            self?.applyCollapsed(true)
        }
        if let t = collapseTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private func cancelAutoCollapse() {
        collapseTimer?.invalidate()
        collapseTimer = nil
    }

    // MARK: 菜单栏图标

    private func buildStatusItem() {
        // 旧恢复版本写入的 0 在当前系统布局中落到了很靠左的位置。
        // 一次迁移回原先的右侧偏移，之后保留用户拖动图标形成的位置。
        if UserDefaults.standard.integer(forKey: "menuBarPlacementVersion") < 1 {
            for name in ["AIReminderStatusItem", "Item-0"] {
                UserDefaults.standard.set(519.0, forKey: "NSStatusItem Preferred Position \(name)")
            }
            UserDefaults.standard.set(1, forKey: "menuBarPlacementVersion")
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true
        item.behavior = []
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "AI到期提醒")
            button.image?.isTemplate = true
            button.image?.size = NSSize(width: 14, height: 16)
            button.title = "到期"
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.imagePosition = .imageLeft
            button.setAccessibilityLabel("AI到期提醒 · 顶部菜单栏")
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "展开胶囊控制", action: #selector(showControls), keyEquivalent: "1")
        menu.addItem(withTitle: "恢复顶部菜单栏图标", action: #selector(restoreMenuBarItem), keyEquivalent: "")
        menu.addItem(withTitle: "桌面悬浮窗归位", action: #selector(restoreToTopRight), keyEquivalent: "")
        menu.addItem(withTitle: "显示 / 隐藏悬浮窗", action: #selector(toggleVisible), keyEquivalent: "")
        menu.addItem(withTitle: "设置后台…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "立即刷新官方数据", action: #selector(refreshClicked), keyEquivalent: "r")
        menu.addItem(.separator())
        let launch = NSMenuItem(title: "常驻（开机自启+崩溃自动拉起）", action: #selector(toggleLaunch), keyEquivalent: "")
        launch.state = Resident.isInstalled() ? .on : .off
        statusLaunchItem = launch
        menu.addItem(launch)
        menu.addItem(withTitle: "打开数据文件夹", action: #selector(openDataFolder), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出（常驻中会自动重启）", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        // 菜单只构建一次，勾选态却会在别处被改（设置后台的复选框、命令行 launchctl）。
        // 挂个 delegate 每次展开前重读真实状态，否则菜单一直在说谎。
        menu.delegate = self
        // 使用系统原生菜单绑定；由 AppKit 完成菜单栏按钮的显示与点击跟踪。
        item.menu = menu
        statusMenu = menu
        statusItem = item
        // macOS 26 在状态栏场景刚创建时同步设置 autosaveName 可能阻止宿主加载。
        // 先完整配置并持有菜单项，再在下一轮主线程循环绑定保存名称。
        // https://github.com/exelban/stats/commit/2a23ab8
        DispatchQueue.main.async { [weak self, weak item] in
            guard let self, let item, self.statusItem === item else { return }
            item.autosaveName = "AIReminderStatusItem"
            item.isVisible = true
        }
        // 原来这行写在 statusItem 赋值之前（`statusItem?.button?...`），是条死语句：
        // 那时 statusItem 还是 nil，tooltip 从没被设上。挪到赋值之后。
        item.button?.toolTip = horizonTooltip(for: visibleItems)
        for delay in [1.0, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak item] in
                guard let self, let item, self.statusItem === item else { return }
                self.writeMenuBarDiagnostics()
            }
        }
    }

    /// 重建系统菜单栏入口，与桌面悬浮窗的位置/展开状态无关。
    /// 系统保存的隐藏状态或旧位置需要一并复位；仅清理本应用自己的菜单栏项。
    @objc func restoreMenuBarItem() {
        // 从右键菜单触发时，先等本轮菜单跟踪结束再拆除它的宿主按钮。
        if menuTrackingDepth > 0 {
            menuBarRestorePending = true
            return
        }
        if let item = statusItem {
            item.autosaveName = nil // AppKit 的公开复位入口：清除持久隐藏状态。
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        statusMenu = nil
        for name in ["AIReminderStatusItem", "Item-0"] {
            UserDefaults.standard.removeObject(forKey: "NSStatusItem Visible \(name)")
            // 默认追加到所有第三方图标左侧可能被应用菜单挤掉。恢复时请求靠近系统图标；
            // 使用本应用的偏好域，不改系统图标、其他应用或全局菜单栏设置。
            UserDefaults.standard.set(519.0, forKey: "NSStatusItem Preferred Position \(name)")
        }
        buildStatusItem()
    }

    /// isVisible 只表示显示意图。记录系统按钮的实际几何位置，供正式运行复核。
    /// 只含本应用 UI 状态，不含提醒记录或其他应用内容。
    private func writeMenuBarDiagnostics() {
        guard let item = statusItem, let button = item.button else { return }
        let frame = button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) } ?? .zero
        let receipt: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "bundle_id": Bundle.main.bundleIdentifier ?? "",
            "captured_at": ISO8601DateFormatter().string(from: Date()),
            "requested_visible": item.isVisible,
            "button_attached_to_window": button.window != nil,
            "window_visible": button.window?.isVisible ?? false,
            "window_has_screen": button.window?.screen != nil,
            "window_occlusion_visible": button.window?.occlusionState.contains(.visible) ?? false,
            "window_alpha": button.window?.alphaValue ?? 0,
            "window_level": button.window?.level.rawValue ?? -1,
            "button_hidden": button.isHiddenOrHasHiddenAncestor,
            "button_alpha": button.alphaValue,
            "button_accessibility_frame": NSStringFromRect(button.accessibilityFrame()),
            "button_screen_frame": ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height],
            "button_window_id": button.window?.windowNumber ?? -1,
            "button_image": button.image != nil,
            "button_title": button.title,
            "item_length": item.length,
            "button_action": button.action.map(NSStringFromSelector) ?? "",
            "screens": NSScreen.screens.map { screen -> [String: Any] in
                ["frame": ["x": screen.frame.minX, "y": screen.frame.minY,
                            "width": screen.frame.width, "height": screen.frame.height],
                 "safe_top": screen.safeAreaInsets.top]
            }
        ]
        let directory = Store.shared.dir.appendingPathComponent("logs", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("menu-bar.json"), options: .atomic)
        } catch { NSLog("菜单栏位置诊断写入失败：%@", error.localizedDescription) }
    }

    /// 每次展开菜单栏图标前重读常驻真实状态：勾选态会被设置后台、命令行 launchctl 改到别处
    func menuNeedsUpdate(_ menu: NSMenu) {
        statusLaunchItem?.state = Resident.isInstalled() ? .on : .off
    }

    // AppKit 的菜单使用系统菜单层级；仅在跟踪菜单时让出这一层，关闭后恢复置顶。
    func menuWillOpen(_ menu: NSMenu) {
        menuTrackingDepth += 1
        beginInteraction()
        panel.level = .floating
    }

    func menuDidClose(_ menu: NSMenu) {
        menuTrackingDepth = max(0, menuTrackingDepth - 1)
        endInteraction()
        restorePresentation()
        if menuTrackingDepth == 0 && menuBarRestorePending {
            menuBarRestorePending = false
            DispatchQueue.main.async { [weak self] in self?.restoreMenuBarItem() }
        }
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "展开 / 收起", action: #selector(toggleCollapseMenu), keyEquivalent: "")
        menu.addItem(withTitle: "＋ 添加订阅（打开设置后台）", action: #selector(addClicked), keyEquivalent: "")
        menu.addItem(withTitle: "⟳ 立即刷新官方数据", action: #selector(refreshClicked), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "打开数据文件夹", action: #selector(openDataFolder), keyEquivalent: "")
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        menu.delegate = self
        return menu
    }

    // MARK: 数据

    private var allItems: [SubItem] {
        (autoItems + Store.shared.manualItems).sorted { $0.expiresAt < $1.expiresAt }
    }

    /// 面板/药丸/菜单栏展示口径：isDisplayable（归档/宽限）并且 isWithinDisplayHorizon（读 displayHorizonDays）。
    /// 官方 auto:* 条目不入 SQLite（archivedAt 恒 nil、永不自愈），它们过期满宽限期后的隐藏
    /// 只能由这里过滤，否则过期项长期排第一、药丸被「已过期」钉死。
    /// buildEntries 的 displayable 必须用同一对判据，否则排序后的 id 集合永远不等，每秒全量重建。
    /// 窗口以外的条目留在数据库，这里只是不展示。已过期仍由 isWithinDisplayHorizon 算在窗口内。
    private var visibleItems: [SubItem] {
        let now = Date()
        return allItems.filter { $0.isDisplayable(now: now) && $0.isWithinDisplayHorizon(now: now) }
    }

    func refreshData() {
        guard !refreshing else { return }
        refreshing = true
        setRefreshIndicator(true)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = ReaderEngine.refreshAll()
            DispatchQueue.main.async {
                guard let self else { return }
                let dismissed = Set(self.Store_dismissedAuto())
                self.autoItems = result.items.filter { !dismissed.contains($0.id) }
                self.refreshing = false
                self.setRefreshIndicator(false)
                // 60 秒自动刷新不能打断正在敲的编辑卡：重建会把卡片换掉、焦点丢失、键入落空。
                // 编辑期间只按 id 原位更新非编辑行的数据，卡片关掉后自然回到正常重建路径。
                if self.editingId != nil {
                    self.updateRowsInPlace(skip: self.editingId)
                } else {
                    self.rebuildAll()
                }
            }
        }
    }

    /// ⟳ 刷新反馈：运行中置灰，结束恢复。否则官方数据没变化时点击毫无观感，用户不知道点没点中。
    private func setRefreshIndicator(_ on: Bool) {
        refreshButton?.isEnabled = !on
        let target: CGFloat = on ? 0.4 : 1
        if Motion.canAnimate {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.refreshButton?.animator().alphaValue = target
            }
        } else {
            refreshButton?.alphaValue = target
        }
    }

    static func upcomingTooltip(_ items: [SubItem]) -> String {
        let now = Date()
        // 与胶囊同一口径：先看未到期的一条条，全部过期才回落（否则 tooltip 头三条永远是过期项）
        let top = upcomingFirst(items, now: now).prefix(3)
        guard !top.isEmpty else { return "暂无到期记录" }
        let lines = top.map { "• \($0.name)：\(Fmt.countdownShort(until: $0.expiresAt, now: now))" }
        return "最近到期\n" + lines.joined(separator: "\n")
    }

    /// 调用处口径：入参已是可见条目。可见集为空但库里还有窗口外的条目时，不要说「暂无」。
    private func horizonTooltip(for items: [SubItem], now: Date = Date()) -> String {
        if items.isEmpty, allItems.contains(where: { !$0.isWithinDisplayHorizon(now: now) }) {
            let n = Store.shared.displayHorizonDays
            return "\(n) 天内没有到期项。更远的已在数据库，临近后再显示"
        }
        return Self.upcomingTooltip(items)
    }

    /// 每秒心跳只做「文本级」刷新；数据级工作由 deadline（滚动）与 dataVersion（重建）驱动。
    /// 睡眠/离线补滚在 deadline 命中的那一秒一次性完成（rollManualWindows 幂等且保持相位）。
    func tick() {
        let now = Date()
        if now >= rollDeadline {
            Store.shared.rollManualWindows(now: now)
            Store.shared.archiveExpiredSubscriptions(now: now)   // 过期 3 天的手动订阅自动归档
            Store.shared.purgeArchived(now: now)                 // 归档 30 天自动清除
            rollDeadline = min(Store.shared.nextRollInstant() ?? .distantFuture, now.addingTimeInterval(3600))
        }

        let items = visibleItems
        let horizonIDs = items.map(\.id).sorted()

        // 提醒不受面板展示天数限制：远期条目也按它自己配置的提前量触发。
        let due = allItems.filter {
            return ReminderTiming.isDue($0, hours: Store.shared.reminderHours(for: $0.id), now: now)
                && !alertedKeys.contains("\($0.id)@\($0.expiresAt.timeIntervalSince1970)")
        }
        if !due.isEmpty {
            due.forEach { alertedKeys.insert("\($0.id)@\($0.expiresAt.timeIntervalSince1970)") }
            presentExpirationAlert(due, now: now)
        }
        flushPendingCriticalAlerts(now: now)

        if !Store.shared.state.panelCollapsed {
            // 只刷倒计时文本：configure() 每秒拆建一次进度条宽度约束，额度条会闪
            for case let row as RowView in rowsContainer.subviews {
                row.refreshCountdown(now: now)
            }
        } else {
            // 即时替换数字；最后一分钟、跨重置点、空库都走同一条稳定布局路径。
            let text = pillText()
            if text != pillLabel.stringValue {
                pillLabel.stringValue = text
                container.setAccessibilityLabel("到期提醒，\(text)，点击展开")
                refitPill()
            }
        }

        // 追踪区只为「移动过的鼠标」补发 enter/exit：拖拽把窗口从静止光标底下搬走、或展开后
        // 指针从未进过面板时，事件一个都不会来，面板就会永远卡在展开态。心跳按真实光标兜底。
        heartbeatPointerResync()

        // 固定沙漏不占用长倒计时的菜单栏宽度；倒计时留在胶囊与提示中。
        controls.refresh()

        // 条目集合有变才重建行、刷新 tooltip；顺带把新增/编辑窗口纳入滚动 deadline。
        // 窗口边界另计：可见 id 会变但 dataVersion 不变。id 没变不重建。
        // 天数另计：displayHorizonDays 变了但可见 id 可能恰好不变，空文案和 tooltip 仍要换数字。
        // 不在这里每秒无条件 rebuildAll。
        let dataChanged = Store.shared.dataVersion != lastSeenDataVersion
        if dataChanged { lastSeenDataVersion = Store.shared.dataVersion }
        let horizonChanged = horizonIDs != lastHorizonIDs
        if horizonChanged { lastHorizonIDs = horizonIDs }
        let horizonDays = Store.shared.displayHorizonDays
        let horizonDaysChanged = horizonDays != lastHorizonDays
        if horizonDaysChanged { lastHorizonDays = horizonDays }
        if dataChanged || horizonChanged || horizonDaysChanged {
            statusItem?.button?.toolTip = horizonTooltip(for: items)
            // id 没变时 rebuildIfNeeded 认为集合未变，不会换掉空列表上的天数。
            if horizonDaysChanged && !horizonChanged {
                rebuildAll()
            } else {
                rebuildIfNeeded(items: items)
            }
        }
        if dataChanged, let next = Store.shared.nextRollInstant() {
            rollDeadline = min(rollDeadline, next)
        }

        tickCount += 1
        // 非主动隐藏的窗口若被系统撤下，下一次心跳立即拉起；不抢走当前应用键盘焦点。
        if !hiddenByUser && !panel.isVisible { restorePresentation() }
        if tickCount % 30 == 0 {
            statusItem?.isVisible = true
            if let btn = statusItem?.button { btn.toolTip = horizonTooltip(for: items) }
            writeMenuBarDiagnostics()
            restorePresentation()
        }
    }

    /// 临期弹窗：NSAlert 模态默认弹在屏幕正中央；.common 模式下 tick 心跳不中断。
    /// 弹窗本身不是提醒渠道，而是把「快到期」这件事顶到眼前——面板常驻右角易被忽视。
    private func presentExpirationAlert(_ due: [SubItem], now: Date) {
        // 已有模态（表单 / 删除确认 / 另一个临期弹窗）在跑：不再叠第二层模态，
        // 暂存进待发队列，由 flushPendingCriticalAlerts 在空闲心跳补弹（alertedKeys 已记账，不重复）。
        guard NSApp.modalWindow == nil else {
            queueCriticalAlerts(due)
            return
        }
        // 上一轮被模态挡下、攒在队列里的条目并进这一次：一次弹完，不逐条轰炸。
        var merged = due
        if !pendingCritical.isEmpty {
            let ids = Set(due.map(\.id))
            merged.append(contentsOf: pendingCritical.filter { !ids.contains($0.id) })
            pendingCritical = []
        }
        // 模态期间可能改了提前量/到期日或删除了记录；补弹前按最新数据重判。
        let ids = Set(merged.map(\.id))
        let sorted = allItems.filter {
            ids.contains($0.id) && ReminderTiming.isDue($0, hours: Store.shared.reminderHours(for: $0.id), now: now)
        }.sorted { $0.expiresAt < $1.expiresAt }
        let validKeys = Set(sorted.map { "\($0.id)@\($0.expiresAt.timeIntervalSince1970)" })
        for item in merged {
            let key = "\(item.id)@\(item.expiresAt.timeIntervalSince1970)"
            if !validKeys.contains(key) { alertedKeys.remove(key) }
        }
        guard !sorted.isEmpty else { return }
        alertedKeys.formUnion(validKeys)
        let list = sorted
            .map { "• \($0.name)——剩 \(Fmt.countdown(until: $0.expiresAt, now: now))（\(Fmt.absTime($0.expiresAt))）\n  \(ReminderTiming.label(hours: Store.shared.reminderHours(for: $0.id)))" }
            .joined(separator: "\n")
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = sorted.count == 1 ? "「\(sorted[0].name)」即将到期" : "\(sorted.count) 条记录即将到期"
        alert.informativeText = list + "\n\n请及时安排使用或续费。"
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        withCollapseSuppressed { FloatingWindowPolicy.runAlert(alert) }
    }

    /// 暂存临期条目（按 id@到期瞬间 去重，重复心跳不会把同一条攒成两份）
    private func queueCriticalAlerts(_ due: [SubItem]) {
        let known = Set(pendingCritical.map { "\($0.id)@\($0.expiresAt.timeIntervalSince1970)" })
        for it in due where !known.contains("\(it.id)@\(it.expiresAt.timeIntervalSince1970)") {
            pendingCritical.append(it)
        }
    }

    /// 模态散场后的补弹：合并成一次弹窗，不逐条轰炸。
    private func flushPendingCriticalAlerts(now: Date) {
        guard !pendingCritical.isEmpty, NSApp.modalWindow == nil else { return }
        let queued = pendingCritical
        pendingCritical = []
        presentExpirationAlert(queued, now: now)
    }

    private func rebuildIfNeeded(items: [SubItem]) {
        // 两侧口径必须一致：currentIds 是分区分组序（额度窗口 → 订阅 → 手动，组内才按到期排），
        // items 是 visibleItems 的全局到期序——直接比数组永远不等，于是每次数据变化都全量重建，
        // 悬停态与正在编辑的内联卡一起被摧毁。两边都改成排序后的 id 集合再比。
        let ids = items.map(\.id).sorted()
        guard ids == currentIds else {
            rebuildAll()
            return
        }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for case let row as RowView in rowsContainer.subviews {
            if let id = row.item?.id, let fresh = byID[id] {
                row.updateItem(fresh)   // updateItem 内部已 configure(now:)，别再配一遍
            }
        }
    }

    /// 不重建地按 id 更新现有行（自动刷新且编辑卡开着时使用）。
    /// 正在编辑的那一行不碰：它的数据由编辑卡自己负责，覆盖会把用户敲了一半的日期换掉。
    private func updateRowsInPlace(skip: String?) {
        // uniquingKeysWith 而非 uniqueKeysWithValues：官方/手动 id 理论上有重名的边界，
        // 这里只是刷数据，不该为此 trap。
        let byID = Dictionary(visibleItems.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        for case let row as RowView in rowsContainer.subviews {
            guard let id = row.item?.id, id != skip, let fresh = byID[id] else { continue }
            row.updateItem(fresh)
        }
    }

    private func makeInlineEditor(_ item: SubItem) -> NSView? {
        guard !item.isAuto else { return nil }
        let editor = InlineEditView(item: item)
        activeInlineView = editor
        editor.onHeightChanged = { [weak self] in self?.rowsContentSizeChanged() }
        editor.onChange = { [weak self] date in self?.inlineChange(id: item.id, date: date) }
        editor.onDelete = { [weak self] in self?.inlineDelete(id: item.id) }
        editor.onEditMore = { [weak self] in self?.inlineEditMore(id: item.id) }
        editor.onDone = { [weak self] in
            self?.editingId = nil
            self?.rebuildAll(animate: true)
        }
        return editor
    }

    /// 展开内容分区：额度窗口 / 订阅 / 手动记录（细色条分隔）
    private func buildEntries() -> [(view: NSView, height: CGFloat)] {
        var entries: [(NSView, CGFloat)] = []
        let byExpiry: ([SubItem]) -> [SubItem] = { $0.sorted { $0.expiresAt < $1.expiresAt } }

        func section(_ title: String, _ items: [SubItem]) {
            guard !items.isEmpty else { return }
            entries.append((SectionHeaderView(title: title), Metrics.sectionH))
            for item in byExpiry(items) {
                let row = RowView()
                row.configure(item, now: Date())
                row.onOpen = { [weak self] in self?.openItem($0) }
                row.onDelete = { [weak self] in self?.deleteItem($0) }
                row.onReminder = { [weak self] item in
                    // 先退出系统菜单跟踪，再进入模态输入窗口。
                    DispatchQueue.main.async { [weak self] in self?.editReminder(item) }
                }
                row.onContextMenu = { [weak self] menu, event, view in
                    menu.delegate = self
                    self?.cancelAutoCollapse()
                    self?.withCollapseSuppressed { NSMenu.popUpContextMenu(menu, with: event, for: view) }
                }
                entries.append((row, Metrics.rowH))
                // 点击条目展开内联编辑卡（README 承诺的行下编辑入口）
                if editingId == item.id, let editor = makeInlineEditor(item) {
                    entries.append((editor, editor.intrinsicContentSize.height))
                }
            }
        }

        // 与 visibleItems 同一判据（isDisplayable && isWithinDisplayHorizon）：比较侧和搭建侧
        // 口径不同会让 id 集合永久不等 → 每次心跳全量重建；官方条目过期后的隐藏也只能在这里生效。
        let displayNow = Date()
        let displayable: (SubItem) -> Bool = {
            $0.isDisplayable(now: displayNow) && $0.isWithinDisplayHorizon(now: displayNow)
        }
        section("额度窗口", autoItems.filter { $0.kind == .window && displayable($0) })
        section("订阅", autoItems.filter { $0.kind == .subscription && displayable($0) })
        section("手动记录", Store.shared.manualItems.filter(displayable))
        if entries.isEmpty {
            let beyondHorizon = allItems.contains { !$0.isWithinDisplayHorizon(now: displayNow) }
            let n = Store.shared.displayHorizonDays
            let hint = NSTextField(labelWithString: beyondHorizon ? "\(n) 天内没有到期项" : "暂无条目，点 ＋ 添加")
            hint.font = .systemFont(ofSize: 9)
            hint.textColor = .tertiaryLabelColor
            // 高度按 Metrics.rowH 记账：layoutChrome 对非分区/非编辑卡的子视图一律按行高摆，
            // 这里报 20 会让 rowsContentH 少算 8pt（实测滚到底差一截）。
            // 不设 frame：宽度由 layoutChrome 按实际内宽统一给，硬编码 180 在窄面板上会溢出。
            entries.append((hint, Metrics.rowH))
        }
        return entries
    }

    /// 重建面板内容。点击时仅让新出现的编辑卡向前浮出；行和窗口直接落在目标位置。
    /// 新视图从零坐标做隐式 frame 动画会让整列条目从底部重新升起。
    private func rebuildAll(animate: Bool = false) {
        // 编辑中的条目已被删除/归档（行内删除、刷新后消失）：编辑态必须一并作废，
        // 否则 scheduleAutoCollapse 会永久抑制自动收起，面板卡在展开态收不回。
        if let eid = editingId,
           Store.shared.manualItems.first(where: { $0.id == eid && $0.isDisplayable() }) == nil {
            editingId = nil
        }
        let openingEditor = animate && editingId != nil && editingId != renderedEditingId
        let entries = buildEntries()
        // 排序后的 id 集合：与 rebuildIfNeeded 的比较侧同口径（那里是全局到期序）
        currentIds = entries.compactMap { ($0.view as? RowView)?.item?.id }.sorted()
        rowsContainer.subviews.forEach { $0.removeFromSuperview() }
        for (view, _) in entries {
            rowsContainer.addSubview(view)
        }
        rowsContentH = entries.reduce(0) { $0 + $1.height + Metrics.spacing }

        // 新建的行没有可供插值的旧位置；关掉隐式动画，避免每次点击都从容器原点上升。
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            self.updateFrame(expanded: !Store.shared.state.panelCollapsed, contentH: self.expandedContentHeight)
        }

        // 只在主动打开另一张编辑卡时播放；数据刷新和关闭不重播。
        if openingEditor, let editor = activeInlineView {
            Motion.popForward(editor)
        }
        renderedEditingId = editingId

        if Store.shared.state.panelCollapsed {
            pillLabel.stringValue = pillText()
        }
    }

    private var expandedContentHeight: CGFloat {
        Metrics.padTop + Metrics.headerH + 3 + rowsContentH + Metrics.padBottom
            + (controlsVisible ? CapsuleControlsView.height + 4 : 0)
    }

    // MARK: 动作

    @objc private func moved() {
        // 自己 setFrame 引发的位移：记账与持久化都不该动
        guard !programmaticMove else { return }
        // 只有胶囊态的 origin 才是「用户要的位置」。展开态 origin 是由右锚点 + 高度
        // 推导出来的中间量，写进 UserDefaults 会让收起后回不到原位、重启后胶囊偏移。
        guard Store.shared.state.panelCollapsed else { return }
        persistPillOrigin()
        // 用户接管了位置：上移展开的「回位」记账作废
        liftedTopY = nil
        expandAnchorTopY = nil
    }

    /// 把当前（胶囊态）窗口原点写进 UserDefaults。
    /// NSValue 不是合法的 plist 类型，直接写入会在 CFPrefs 校验时抛异常崩溃 → 存 Double 数组。
    private func persistPillOrigin() {
        let o = panel.frame.origin
        UserDefaults.standard.set([Double(o.x), Double(o.y)], forKey: "panelOrigin")
    }

    /// 系统模态（确认框 / 三键删组弹窗 / 临期弹窗 / 官方条目说明）期间统一走抑制器。
    /// runModal 在 .common 模式下照样跑心跳与 mouseExited，光标一离开面板就重挂 8 秒表，
    /// 收起会把底下的面板连同正在编辑的内联卡一起撤掉。前后成对，按真实光标位置恢复节奏。
    /// withCollapseSuppressed 的返回值大多不用（runModal 的按钮结果），标可丢弃避免告警。
    @discardableResult
    private func withCollapseSuppressed<T>(_ body: () -> T) -> T {
        beginInteraction()
        defer { endInteraction() }
        return body()
    }

    private func beginInteraction() {
        suppressDepth += 1
        collapseSuppressor.begin()
        cancelAutoCollapse()
    }

    private func endInteraction() {
        suppressDepth = max(0, suppressDepth - 1)
        // 菜单、月历、模态可嵌套，只有最后一层结束才恢复自动收起。
        if suppressDepth == 0, collapseSuppressor.end(cursorInsidePanel: isCursorInsidePanel()) {
            scheduleAutoCollapse()
        }
    }

    /// ➕：打开设置后台并弹出添加表单
    @objc private func addClicked() {
        NSApp.activate(ignoringOtherApps: true)
        ensureSettings().openForAdd()
    }

    /// 点击条目：手动条目 → 行下展开内联编辑卡；官方条目 → 说明
    private func openItem(_ item: SubItem) {
        cancelAutoCollapse()   // 说明/编辑期间不自动收起（模态运行在 .common 模式下计时器仍会触发）
        guard !item.isAuto else {
            // 模态会吞掉 mouseUp：先恢复按压态，避免行卡在半透明
            for case let row as RowView in rowsContainer.subviews {
                Motion.press(row, pressed: false)
            }
            // 模态期间 mouseExited 仍会重挂收起定时器 → 用抑制器拦住；结束后按光标位置恢复
            let alert = NSAlert()
            alert.messageText = item.name
            alert.informativeText = "来源：\(item.source) 官方本地数据\n到期：\(Fmt.absTime(item.expiresAt))\n\(item.note)\n（官方数据每次刷新自动更新，如需自定义请手动添加）"
            withCollapseSuppressed { FloatingWindowPolicy.runAlert(alert) }
            return
        }
        // 手动条目：编辑卡的抑制由 scheduleAutoCollapse 的 editingId 闸门统一负责
        // （卡片有 4 条关闭路径，逐处 begin/end 迟早漏一条把面板永久钉在展开态）
        editingId = (editingId == item.id) ? nil : item.id   // 再点一次收起
        rebuildAll(animate: true)
        if editingId != nil { scrollEditorIntoViewIfNeeded() }
    }

    private func editReminder(_ selected: SubItem) {
        guard let item = allItems.first(where: { $0.id == selected.id }) else { return }
        cancelAutoCollapse()
        let controller = ReminderTimingController(item: item, hours: Store.shared.reminderHours(for: item.id))
        controller.onSave = { Store.shared.setReminderHours($0, for: item.id) }
        if withCollapseSuppressed({ controller.runModal() }) == .OK { updateRowsInPlace(skip: nil) }
    }

    /// 高度封顶 + 滚动引入后的补充：点视口下部/上部的行时，编辑卡可能整个落在折叠区，
    /// 用户看起来像「点了没反应」。打开后把卡片平移进可视范围（内容够滚时）。
    /// AppKit y 向上：卡片超出视口下缘（maxY > viewport）要减小 offset（往上滚回）。
    private func scrollEditorIntoViewIfNeeded() {
        guard viewportH > 0, rowsContentH > viewportH, let editor = activeInlineView else { return }
        let card = rowsClip.convert(editor.frame, from: editor.superview ?? rowsContainer)
        let viewport = rowsClip.bounds.height
        let maxOffset = max(0, rowsContentH - viewportH)
        let needsScroll = card.maxY > viewport + 0.5 || card.minY < -0.5
        guard needsScroll else { return }
        if card.maxY > viewport + 0.5 {
            scrollOffset = max(scrollOffset - (card.maxY - viewport), 0)
        } else {
            scrollOffset = min(scrollOffset - card.minY, maxOffset)
        }
        // 平滑滚到卡片可见，不是瞬移
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            self.layoutChrome()
        }
    }

    /// 光标（屏幕坐标）是否位于面板**整个内容区**（含 header 工具条与内边距，
    /// 与 PanelContainerView 追踪区范围一致）。仅用 rect 版系统转换，避免点/矩形重载歧义
    private func isCursorInsidePanel() -> Bool {
        guard let content = panel.contentView, let win = content.window else { return false }
        let boundsInWindow = content.convert(content.bounds, to: nil)
        let inScreen = win.convertToScreen(boundsInWindow)
        return inScreen.contains(PanelController.debugCursorOverride ?? NSEvent.mouseLocation)
    }

    /// 内联编辑卡回调
    private func inlineChange(id: String, date: Date) {
        guard let persisted = Store.shared.manualItems.first(where: { $0.id == id }) else { return }
        var it = persisted                    // 已持久化的旧值：写失败时行显示回退到此，避免假数据
        it.expiresAt = date
        // 编辑路径：保留既有重置模型，滚动伴生窗口锚点按到期差值平移
        let result = Store.shared.updateManual(it, previousExpiry: persisted.expiresAt)
        let displayItem = result.saved ? it : persisted
        for case let row as RowView in rowsContainer.subviews where row.item?.id == id {
            row.updateItem(displayItem)
        }
        // 卡片内现有界面反馈（不发系统通知/飞书）；对齐失败证据留存 Store.lastAlignmentFailures
        switch result {
        case .savedWithAlignFailure(let failures):
            // 失败提示持续显示（autoHide=false），直到下一次成功写入或卡片关闭
            activeInlineView?.showStatus("已保存，但 \(failures.count) 项关联同步失败", color: .systemRed, autoHide: false)
            NSLog("AR: 内联保存对齐失败 \(failures.joined(separator: ","))")
        case .parentFailed:
            activeInlineView?.showStatus("保存失败，请重试", color: .systemRed, autoHide: false)
            NSLog("AR: 内联保存写入失败")
        case .success:
            activeInlineView?.clearStatus()   // 成功写入清除失败提示
        default:
            break
        }
    }

    private func inlineDelete(id: String) {
        editingId = nil
        if let it = Store.shared.manualItems.first(where: { $0.id == id }) {
            deleteItem(it)
        }
    }

    private func inlineEditMore(id: String) {
        guard let it = Store.shared.manualItems.first(where: { $0.id == id }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        ensureSettings().openForEdit(it)
    }

    /// 悬浮窗行内直接删除（一律先确认）：
    /// 官方条目 → 确认后隐藏（⟳ 刷新即恢复）；手动条目 → 确认后删；按周组 → 询问整组/单条
    private func deleteItem(_ item: SubItem) {
        if editingId == item.id { editingId = nil }
        if item.isAuto {
            guard withCollapseSuppressed({
                DeleteConfirm.run(item, verb: "隐藏",
                                  hint: "官方数据本地仍会更新，点 ⟳ 刷新官方数据即可恢复显示")
            }) else { return }
            if !Store.shared.state.dismissedAuto.contains(item.id) {
                Store.shared.state.dismissedAuto.append(item.id)
                Store.shared.save()
            }
            if let idx = autoItems.firstIndex(where: { $0.id == item.id }) {
                autoItems.remove(at: idx)
            }
            rebuildAll(animate: true)
            return
        }
        if let gid = item.groupID {
            let members = Store.shared.manualItems.filter { $0.groupID == gid }
            if members.count > 1 {
                let alert = NSAlert()
                alert.messageText = "「\(item.name)」属于按周划分组（共 \(members.count) 条）"
                alert.informativeText = "要删除整组，还是仅删除这一条？删除后不可恢复。"
                let allBtn = alert.addButton(withTitle: "删除整组(\(members.count))")
                alert.addButton(withTitle: "仅此条")
                alert.addButton(withTitle: "取消")
                allBtn.hasDestructiveAction = true
                allBtn.contentTintColor = .systemRed
                alert.buttons.last?.keyEquivalent = "\r"   // 回车默认 = 取消，防误删
                NSApp.activate(ignoringOtherApps: true)
                switch withCollapseSuppressed({ FloatingWindowPolicy.runAlert(alert) }) {
                case .alertFirstButtonReturn:
                    Store.shared.deleteGroup(gid)
                case .alertSecondButtonReturn:
                    Store.shared.deleteManualWithDerived(item.id)
                default:
                    return
                }
                rebuildAll(animate: true)
                return
            }
        }
        guard withCollapseSuppressed({
            DeleteConfirm.run(item, hint: "手动录入的信息删除后不可恢复，需要重新录入")
        }) else { return }
        Store.shared.deleteManualWithDerived(item.id)
        rebuildAll(animate: true)
    }

    private func Store_dismissedAuto() -> [String] {
        Store.shared.state.dismissedAuto
    }

    private func ensureSettings() -> SettingsWindowController {
        if settings == nil { settings = SettingsWindowController(panel: self) }
        return settings!
    }

    /// 供设置后台读取当前全部条目
    func snapshotItems() -> [SubItem] { allItems }

    /// 供设置后台打开编辑表单（挂在设置窗口上）
    func openEditor(_ item: SubItem, isNew: Bool, on parent: NSWindow,
                    saved: @escaping () -> Void, deleted: @escaping () -> Void) {
        if item.isAuto {
            let alert = NSAlert()
            alert.messageText = item.name
            alert.informativeText = "来源：\(item.source) 官方本地数据\n到期：\(Fmt.absTime(item.expiresAt))\n\(item.note)\n（官方数据每次刷新自动更新，如需自定义请手动添加）"
            withCollapseSuppressed { FloatingWindowPolicy.runAlert(alert) }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let editor = EditorSheetController(item: item, isNew: isNew)
        editor.window?.isReleasedWhenClosed = false
        activeEditors.append(editor)   // 保活：否则控制器释放后按钮 target 变 nil
        // 回收只挂关闭回调：保存成功/确认删除后表单都会 endSheet，取消与 Esc 同样会。
        // 原先在 onSave/onDelete 闭包里 removeAll { $0 === editor } 有两宗罪：
        // 闭包存在 editor 上又强捕获 editor 自己（editor → onSave → editor 自引用环，
        // 永远释放不掉），而且漏掉「取消」这条最常用的退出路径。
        editor.onClose = { [weak self, weak editor] in
            guard let self, let editor else { return }
            self.activeEditors.removeAll { $0 === editor }
        }
        editor.onSave = { savedItem, previousExpiry, weeklyAnchor in
            EditorSheetController.lastSaveFailureMessage = nil
            let result: ManualWriteResult
            if let weeklyAnchor {
                // 订阅 · 周额度重置：按官方节奏拆「第k/n周」组；编辑时替换原单条
                result = Store.shared.saveWeeklySplit(name: savedItem.name, vendor: savedItem.vendor,
                                                      expiry: savedItem.expiresAt, firstReset: weeklyAnchor,
                                                      replacing: isNew ? nil : savedItem.id)
            } else if let previousExpiry {
                // 编辑：保留既有重置规则，滚动伴生窗口锚点由 Store 按到期差值平移；
                // 条目转为周期窗口时冗余伴生由 Store 一并清理
                result = Store.shared.updateManual(savedItem, previousExpiry: previousExpiry)
            } else if savedItem.kind == .window {
                // 新建即选周期额度：显式滚动窗口，绕过推断
                result = Store.shared.saveWindow(name: savedItem.name, vendor: savedItem.vendor,
                                                 expiresAt: savedItem.expiresAt,
                                                 repeatHours: savedItem.repeatHours ?? 168)
            } else {
                // 一次性类型不依据供应商猜测额度窗口。
                result = Store.shared.saveOneTime(name: savedItem.name, vendor: savedItem.vendor,
                                                  expiresAt: savedItem.expiresAt)
            }
            if result.saved {
                saved()
            }
            if case .savedWithAlignFailure(let failures) = result {
                // 明确哪些关联未同步；证据留存于 Store.lastAlignmentFailures，恢复方案另行处理
                EditorSheetController.lastSaveFailureMessage =
                    "已保存，但以下关联未能同步：\(failures.joined(separator: "、"))"
            }
            return result.saved
        }
        editor.onDelete = { [weak self] id in
            guard let self,
                  let it = Store.shared.manualItems.first(where: { $0.id == id }),
                  self.withCollapseSuppressed({
                      DeleteConfirm.run(it, hint: "手动录入的信息删除后不可恢复，需要重新录入")
                  }) else { return false }
            Store.shared.deleteManualWithDerived(id)
            deleted()
            return true
        }
        parent.beginSheet(editor.window!)
        Motion.reveal(editor.window!.contentView!)   // 每次点开表单都虚化渐入
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        ensureSettings().showWindow(nil)
    }

    @objc func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        ensureSettings().showWindow(nil)
    }

    @objc private func refreshClicked() {
        if !Store.shared.state.dismissedAuto.isEmpty {
            Store.shared.state.dismissedAuto = []
            Store.shared.save()
        }
        refreshData()
    }

    @objc private func toggleCollapseMenu() {
        applyCollapsed(!Store.shared.state.panelCollapsed)
    }

    @objc private func hideClicked() {
        hiddenByUser = true
        Motion.dismissWindow(panel)   // 淡出退场，不是凭空消失
    }

    @objc func restoreToTopRight() {
        let targetScreen = panel.isVisible ? panel.screen : Self.operationScreen
        hiddenByUser = false
        CalendarPickerController.shared.dismiss()
        applyCollapsed(true)
        moveToTopRight(on: targetScreen)
        restorePresentation()
        Motion.reveal(panel)
    }

    private static var operationScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
    }

    private func moveToTopRight(on screen: NSScreen? = nil) {
        let screen = screen ?? Self.operationScreen
        guard let frame = screen?.visibleFrame else { return }
        let target = NSPoint(x: frame.maxX - Metrics.dockMargin - panel.frame.width,
                             y: frame.maxY - Metrics.screenMargin - panel.frame.height)
        programmaticMove = true
        // 归位是一次平滑滑动，不是瞬移（月历锚定期除外，同 frameAnimationDuration）
        Motion.animateWindowFrame(panel, to: NSRect(origin: target, size: panel.frame.size),
                                  duration: CalendarPickerController.shared.isVisible ? 0 : 0.35) { [weak self] in self?.programmaticMove = false }
        // 动画期间 panel.frame 还在起点，持久化必须写目标值（胶囊态才认 origin）
        if Store.shared.state.panelCollapsed {
            UserDefaults.standard.set([Double(target.x), Double(target.y)], forKey: "panelOrigin")
        }
        liftedTopY = nil
        expandAnchorTopY = nil
    }

    @objc private func restorePresentation() {
        guard !hiddenByUser else { return }
        panel.level = menuTrackingDepth > 0 ? .floating : FloatingWindowPolicy.panelLevel
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
            moveToTopRight()
        }
        panel.orderFrontRegardless()
    }

    @objc private func toggleVisible() {
        if panel.isVisible { hideClicked() } else { showPanel() }
    }

    @objc private func toggleLaunch() {
        _ = Resident.toggle()   // 常驻真实状态只有 launchd 一份，菜单勾选在 menuNeedsUpdate 里重读
    }

    @objc private func openDataFolder() {
        // 走 Store.shared.dir：与设置后台同一个口径，认 AR_DATA_DIR 注入且不再 urls(for:).first!
        let dir = Store.shared.dir
        guard FileManager.default.fileExists(atPath: dir.path) else {
            NSLog("AR: 数据目录不存在：\(dir.path)")
            return
        }
        NSWorkspace.shared.open(dir)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func showPanel() {
        hiddenByUser = false
        // 首次启动且还没有任何条目：自动展开一次，把「暂无条目，点 ＋ 添加」送到眼前。
        // 标记在任何首启都置位——老用户升级后（库非空）不弹，之后清空条目也不重复弹。
        if Store.shared.state.autoExpandDone == nil {
            Store.shared.state.autoExpandDone = true
            let emptyFirstRun = visibleItems.isEmpty && Store.shared.state.panelCollapsed
            Store.shared.state.panelCollapsed = emptyFirstRun ? false : Store.shared.state.panelCollapsed
            Store.shared.save()
        }
        applyCollapsed(Store.shared.state.panelCollapsed)
        restorePresentation()
        Motion.reveal(panel)
    }

    @objc func showControls() {
        hiddenByUser = false
        setControlsShown(true)
        if Store.shared.state.panelCollapsed {
            applyCollapsed(false)
        } else {
            updateFrame(expanded: true, contentH: expandedContentHeight)
        }
        NSApp.activate(ignoringOtherApps: true)
        restorePresentation()
        panel.makeKeyAndOrderFront(nil)
        cancelAutoCollapse()
    }

    @objc private func toggleControls() {
        setControlsShown(!controlsVisible)
        updateFrame(expanded: true, contentH: expandedContentHeight)
    }

    var debugControls: CapsuleControlsView { controls }
    var debugStatusItem: NSStatusItem? { statusItem }

    // MARK: 自测渲染支持

    /// TestRender 注入：非 nil 时代替真实光标参与悬停/自动收起判定，正式运行恒为 nil。
    static var debugCursorOverride: NSPoint?

    var debugContentView: NSView? { container }
    /// TestRender 断言用：跑一次心跳兜底重算（tick() 里同一段，测试避免触发临期模态弹窗）
    func debugHeartbeatResync() { heartbeatPointerResync() }
    /// TestRender 断言用：计时器触发时刻；重复心跳不得把它一路往后推
    var debugCollapseFireDate: Date? { collapseTimer?.fireDate }
    /// TestRender 断言用：自动收起计时器是否已挂（悬停记账错位会表现为常驻或永不收起）
    var debugCollapseScheduled: Bool { collapseTimer != nil }
    /// TestRender 断言失败时的定位口：scheduleAutoCollapse 有四个闸门，
    /// 光看 collapseTimer==nil 分不清是哪个挡住的。
    var debugCollapseGate: (suppressed: Bool, editingId: String?, collapsed: Bool, cursorInside: Bool) {
        (collapseSuppressor.isSuppressed, editingId,
         Store.shared.state.panelCollapsed, isCursorInsidePanel())
    }
    /// TestRender 断言用：原尺寸胶囊的当前适配字号。
    var debugPillFontSize: CGFloat { pillLabel.font?.pointSize ?? 0 }
    var debugPillLabel: NSTextField { pillLabel }
    func debugShowInlineEditor() {
        if let first = Store.shared.manualItems.first(where: { !$0.isAuto }) {
            editingId = first.id
        }
        rebuildAll()
    }
    /// 与 debugShowInlineEditor 对偶：编辑卡会抑制自动收起（scheduleAutoCollapse 的闸门），
    /// 截完图不关掉，后面的悬停/收起记账断言就是在「编辑中」状态下跑的，结论失真。
    func debugHideInlineEditor() {
        guard editingId != nil else { return }
        editingId = nil
        rebuildAll()
    }
    // MARK: 自测渲染支持（行区滚动）
    var debugScrollOffset: CGFloat { scrollOffset }
    var debugRowsContentH: CGFloat { rowsContentH }
    var debugViewportH: CGFloat { viewportH }
    var debugScrollIndicatorVisible: Bool { !scrollIndicator.isHidden }
    var debugRowsOriginY: CGFloat { rowsContainer.frame.origin.y }
    /// 最后一行的窗口坐标（滚动到底后应完整落在窗口 bounds 内）
    var debugLastSubviewWindowRect: NSRect? {
        guard let last = rowsContainer.subviews.last else { return nil }
        let inClip = rowsClip.convert(last.frame, from: rowsContainer)
        return rowsClip.convert(inClip, to: nil)
    }
    func debugApplyScroll(_ deltaY: CGFloat) { applyScroll(deltaY: deltaY) }
    // MARK: 自测渲染支持（刷新反馈）
    var debugRefreshIndicatorOn: Bool { refreshButton.map { !$0.isEnabled } ?? false }
    func debugSetRefreshIndicator(_ on: Bool) { setRefreshIndicator(on) }
    /// TestRender 断言用：右键菜单宿主（container 持有非 nil 菜单 = 右键可达）
    var debugContextMenu: NSMenu? { container.menu }
    func debugSetExpanded(_ expanded: Bool) {
        Store.shared.state.panelCollapsed = !expanded
        rebuildAll()
    }
}
