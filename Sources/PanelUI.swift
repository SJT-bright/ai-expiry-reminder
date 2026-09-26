import AppKit

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
        return alert.runModal() == .alertSecondButtonReturn
    }
}

// MARK: - 玻璃质感工具

enum Glass {
    static func apply(_ v: NSVisualEffectView, corner: CGFloat) {
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = corner
        v.layer?.masksToBounds = true
        v.layer?.borderWidth = 1
        v.layer?.borderColor = NSColor(white: 1, alpha: 0.32).cgColor
        v.layer?.backgroundColor = NSColor(white: 0.10, alpha: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 0.96 : 0.16).cgColor
        v.layer?.cornerCurve = .continuous
    }

    /// 让一个带标题栏的窗口变成半透明玻璃窗
    static func glassWindow(_ w: NSWindow) {
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.styleMask.insert(.fullSizeContentView)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.appearance = NSAppearance(named: .darkAqua)
    }
}

/// 原生背景模糊上叠加柔和反光；装饰层不截获点击。
final class FrostedGlassSurface: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let radius = layer?.cornerRadius ?? 16
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.7, dy: 0.7),
                                 xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSGradient(colors: [NSColor(white: 1, alpha: 0.20),
                            NSColor(white: 1, alpha: 0.015),
                            NSColor(white: 0, alpha: 0.10)])?.draw(in: bounds, angle: -90)
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
                               xRadius: max(0, radius - 1), yRadius: max(0, radius - 1))
        NSColor(white: 1, alpha: 0.13).setStroke()
        edge.lineWidth = 0.6
        edge.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// macOS 26 使用系统液态玻璃，旧系统保留原生毛玻璃和边缘反光。
final class GlassSurface: NSView {
    private let surface: NSView
    var cornerRadius: CGFloat = 18 {
        didSet {
            if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView {
                glass.cornerRadius = cornerRadius
            } else {
                surface.layer?.cornerRadius = cornerRadius
                surface.needsDisplay = true
            }
        }
    }
    override init(frame: NSRect) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.appearance = NSAppearance(named: .darkAqua)
            glass.cornerRadius = 18
            glass.tintColor = NSColor(calibratedRed: 0.10, green: 0.17, blue: 0.22, alpha: 0.35)
            // 保留外缘折射，内部用薄暗色层稳定浅色壁纸上的文字对比。
            let backing = NSView()
            backing.wantsLayer = true
            backing.layer?.backgroundColor = NSColor(white: 0.025, alpha: 0.48).cgColor
            glass.contentView = backing
            surface = glass
        } else {
            let glass = FrostedGlassSurface()
            Glass.apply(glass, corner: 18)
            surface = glass
        }
        super.init(frame: frame)
        addSubview(surface)
        surface.autoresizingMask = [.width, .height]
        surface.frame = bounds
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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

/// 容器视图：跟踪鼠标进出（自动收起），并处理「收起态点击展开」
final class PanelContainerView: NSView {
    var onMouseEnter: (() -> Void)?
    var onMouseExit: (() -> Void)?
    var onBackgroundClick: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onMouseEnter?() }
    override func mouseExited(with event: NSEvent) { onMouseExit?() }

    // 点击空白处（收起态 = 展开面板）。按钮等控件自己消费点击，不会走到这里。
    override func mouseDown(with event: NSEvent) {
        onBackgroundClick?()
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
    private let hoverBg = CALayer()
    private var barFillWidth: NSLayoutConstraint?
    private(set) var item: SubItem?
    var onOpen: ((SubItem) -> Void)?
    var onDelete: ((SubItem) -> Void)?

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 28)
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        hoverBg.backgroundColor = NSColor(white: 1, alpha: 0.05).cgColor
        hoverBg.cornerRadius = 6
        hoverBg.opacity = 0
        layer?.addSublayer(hoverBg)
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
            subLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
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

    override func layout() {
        super.layout()
        // 手动托管子层不会随视图自动布局，必须在每次布局时同步尺寸，否则高亮恒为 0×0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverBg.frame = bounds
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
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
        hoverBg.opacity = 0
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    /// 悬停反馈：整行垂直浮起 + 背景高亮；移出落下。
    /// 不做横向缩放——近满宽的行以中心放大会把行内文字左右各推出 4pt+，与邻行错位（观感「浮歪」）
    override func mouseEntered(with event: NSEvent) {
        Motion.float(self, on: true, scale: 1.0, lift: 1.2)
        hoverBg.opacity = 1
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

    func configure(_ item: SubItem, now: Date) {
        self.item = item
        let color = Self.urgencyColor(item, now: now)
        dot.layer?.backgroundColor = color.cgColor
        var prefix = ""
        if let used = item.usedPercent {
            subLabel.stringValue = "\(item.vendor) · \(Fmt.absTime(item.expiresAt)) · 剩余\(Int(100 - used))%"
            let ratio = CGFloat(max(0, min(used, 100))) / 100.0
            barFillWidth?.isActive = false
            barFillWidth = barFill.widthAnchor.constraint(equalTo: barTrack.widthAnchor, multiplier: ratio)
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
                     "来源：\(item.isAuto ? "官方本地数据" : "手动添加")"]
        if let used = item.usedPercent {
            var pace = "额度剩余 \(Int(100 - used))%"
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

// MARK: - 内联编辑卡（悬浮窗内直接调整到期时间）

final class InlineEditView: NSView {
    var onChange: ((Date) -> Void)?
    var onDelete: (() -> Void)?
    var onEditMore: (() -> Void)?
    var onDone: (() -> Void)?

    private let datePicker = NSDatePicker()
    private let statusLabel = NSTextField(labelWithString: "")
    private var statusResetTimer: Timer?

    /// 卡片内的现有界面反馈（如对齐同步失败），不依赖系统通知
    /// 卡片内的现有界面反馈（不发系统通知/飞书）
    /// autoHide=false：失败类提示持续显示，直到下一次成功写入（clearStatus）或卡片关闭
    func showStatus(_ text: String, color: NSColor, autoHide: Bool = true) {
        statusLabel.stringValue = text
        statusLabel.textColor = color
        statusLabel.isHidden = false
        invalidateIntrinsicContentSize()
        Motion.fadeIn(statusLabel)
        statusResetTimer?.invalidate()   // 先取消旧计时器，再按本次语义决定是否隐藏
        statusResetTimer = nil
        guard autoHide else { return }
        statusResetTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            self?.statusLabel.isHidden = true
            self?.invalidateIntrinsicContentSize()
        }
    }

    /// 清除状态行（下一次成功写入时调用，解除失败持续提示）
    func clearStatus() {
        statusResetTimer?.invalidate()
        statusResetTimer = nil
        guard !statusLabel.isHidden else { return }
        statusLabel.isHidden = true
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: statusLabel.isHidden ? 92 : 106)
    }

    init(item: SubItem) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        layer?.cornerRadius = 7

        func quick(_ title: String, _ seconds: TimeInterval) -> NSButton {
            let b = HoverEffectButton(title: title, target: self, action: #selector(quick(_:)))
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 9)
            b.tag = Int(seconds)
            return b
        }
        let quickRow = NSStackView(views: [quick("＋1小时", 3600), quick("＋1天", 86400),
                                           quick("＋1周", 7 * 86400), quick("＋30天", 30 * 86400)])
        quickRow.orientation = .horizontal
        quickRow.spacing = 4

        datePicker.datePickerElements = [.yearMonthDay, .hourMinute]
        datePicker.datePickerStyle = .textField
        datePicker.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        datePicker.dateValue = item.expiresAt
        datePicker.target = self
        datePicker.action = #selector(dateChanged)

        let delBtn = HoverEffectButton(title: "删除", target: self, action: #selector(delTapped))
        delBtn.bezelStyle = .rounded
        delBtn.controlSize = .small
        delBtn.contentTintColor = .systemRed
        let moreBtn = HoverEffectButton(title: "更多设置…", target: self, action: #selector(moreTapped))
        moreBtn.bezelStyle = .rounded
        moreBtn.controlSize = .small
        let doneBtn = HoverEffectButton(title: "完成", target: self, action: #selector(doneTapped))
        doneBtn.bezelStyle = .rounded
        doneBtn.controlSize = .small
        doneBtn.keyEquivalent = "\r"
        let actRow = NSStackView(views: [delBtn, NSView(), moreBtn, doneBtn])
        actRow.orientation = .horizontal
        actRow.spacing = 6
        actRow.views.first?.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [quickRow, datePicker, actRow, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        statusLabel.font = .systemFont(ofSize: 9)
        statusLabel.textColor = .systemRed
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -7),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func quick(_ sender: NSButton) {
        datePicker.dateValue = datePicker.dateValue.addingTimeInterval(TimeInterval(sender.tag))
        dateChanged()
    }

    @objc private func dateChanged() {
        onChange?(datePicker.dateValue)
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

    /// 自测开关：关闭后保存失败不弹系统弹窗（TestRender 断言表单行为时使用）
    static var showsSaveFailureAlerts = true
    /// 最近一次保存失败的提示文案（含部分失败）；自测断言用
    static var lastSaveFailureMessage: String?

    private var item: SubItem
    private let isNew: Bool
    private let previousExpiry: Date

    private let nameField = NSTextField(string: "")
    private let vendorCombo = NSComboBox()
    /// 类型档位：0 一次性 / 1 订阅周额度重置 / 2 每周窗口 / 3 每月窗口 / 4 5小时窗口 / 5 动态「保持现有」
    private let typePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// 「订阅 · 周额度重置」档的首次重置锚点（官方节奏起点；缺省 = 现在 + 7 天）
    private let firstResetPicker = NSDatePicker()
    private var firstResetRow: NSGridRow?
    private let datePicker = NSDatePicker()
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
        super.init(window: win)
        buildForm()
        load()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 当前输入组合解析出的供应商（与 Store.saveInferred 同规则，仅用于实时预览）
    private func resolvedVendor() -> String {
        let v = vendorCombo.stringValue.trimmingCharacters(in: .whitespaces)
        if !v.isEmpty { return v }
        return VendorResetKnowledge.vendor(for: nameField.stringValue) ?? "未分类"
    }

    /// 保存时底层将如何处理（仅预览；真正的写入在 Store.saveInferred / saveWindow / saveWeeklySplit）
    private func updatePreview() {
        firstResetRow?.isHidden = typePopup.indexOfSelectedItem != 1
        switch typePopup.indexOfSelectedItem {
        case 1:
            let span = datePicker.dateValue.timeIntervalSince(firstResetPicker.dateValue)
            guard span.isFinite, span >= 0, span < 520 * 7 * 86400 else {
                previewLabel.stringValue = "最多拆分 520 周，请检查首次重置和到期日期"
                break
            }
            let plan = QuotaAdvice.weeklyPlan(expiry: datePicker.dateValue,
                                              firstReset: firstResetPicker.dateValue)
            let schedule = plan.resets.map { Fmt.shortDate($0) }.joined(separator: " → ")
            previewLabel.stringValue = "排期共 \(plan.resets.count) 轮：\(schedule)\n" + plan.advice.joined(separator: "\n")
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
        firstResetPicker.datePickerElements = [.yearMonthDay, .hourMinute]
        firstResetPicker.datePickerStyle = .textField
        firstResetPicker.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        firstResetPicker.dateValue = item.expiresAt   // 默认保留用户已填写的本轮到期锚点；可明确改为实际首次重置
        firstResetPicker.target = self
        firstResetPicker.action = #selector(inputChanged)
        datePicker.datePickerElements = [.yearMonthDay, .hourMinute]
        datePicker.datePickerStyle = .textField
        datePicker.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        datePicker.target = self
        datePicker.action = #selector(inputChanged)
        previewLabel.font = .systemFont(ofSize: 9.5)
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.maximumNumberOfLines = 3   // 排期 + 建议可占多行
        statusLabel.font = .systemFont(ofSize: 9)
        statusLabel.textColor = .systemRed
        statusLabel.isHidden = true

        func quickBtn(_ title: String, _ seconds: TimeInterval) -> NSButton {
            let b = HoverEffectButton(title: title, target: self, action: #selector(quickSet(_:)))
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.tag = Int(seconds)
            return b
        }
        let quickRow = NSStackView(views: [quickBtn("＋1小时", 3600), quickBtn("＋1天", 86400),
                                           quickBtn("＋1周", 7 * 86400), quickBtn("＋30天", 30 * 86400)])
        quickRow.orientation = .horizontal
        quickRow.spacing = 6
        let dateRow = NSStackView(views: [datePicker, quickRow])
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

        let grid = NSGridView(views: [
            [label("名称"), nameField],
            [label("类型"), typePopup],
            [label("到期时间"), dateRow],
            [label("首次重置"), firstResetPicker],
            [label("供应商"), vendorCombo],
            [NSView(), infoStack],
        ])
        firstResetRow = grid.row(at: 3)
        firstResetRow?.isHidden = true
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 80
        grid.rowSpacing = 8
        grid.columnSpacing = 8
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

        let glass = NSVisualEffectView()
        Glass.apply(glass, corner: 0)
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
        datePicker.dateValue = item.expiresAt
        loadTypeSelection()
        updatePreview()
    }

    // 表单极简后任何输入变化都只影响推断预览，共用一个刷新入口
    @objc private func inputChanged() { updatePreview() }

    /// 快捷按钮始终沿已填写的时间累加
    @objc private func quickSet(_ sender: NSButton) {
        datePicker.dateValue = datePicker.dateValue.addingTimeInterval(TimeInterval(sender.tag))
        updatePreview()
    }

    @objc private func cancelClicked() {
        window?.sheetParent?.endSheet(window!)
    }

    @objc private func deleteClicked() {
        // 仅在真正删除后才关闭表单；用户在确认框点取消时保持表单打开
        if onDelete?(item.id) == true {
            window?.sheetParent?.endSheet(window!)
        }
    }

    @objc private func saveClicked() {
        var it = item
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        it.name = (isNew || !name.isEmpty) ? name : item.name   // 编辑时清空名称视为不改
        // 供应商留空原样上交：保存管线会按名称识别厂商，表单预览与底层用同一套规则
        it.vendor = vendorCombo.stringValue.trimmingCharacters(in: .whitespaces)
        it.expiresAt = datePicker.dateValue
        it.source = "manual"
        // 类型档位：显式声明优先于推断；「保持现有」档不动周期与重置规则
        var weeklyAnchor: Date?
        switch typePopup.indexOfSelectedItem {
        case 1:
            // 订阅 · 周额度重置：官方节奏自首次重置每 7 天一档，拆「第k/n周」组
            let anchor = firstResetPicker.dateValue
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
            }
        case 6:
            if let h = it.repeatHours {
                it.purchaseAt = it.expiresAt.addingTimeInterval(-h * 3600)   // 倒推窗口起点
            }
        default:
            it.kind = .subscription
            it.repeatHours = nil
            it.resetRule = nil
            it.resetParam = nil
        }

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
                alert.runModal()
            }
            return
        }
        window?.sheetParent?.endSheet(window!)
        if let msg = Self.lastSaveFailureMessage, Self.showsSaveFailureAlerts {
            let alert = NSAlert()
            alert.messageText = "部分保存失败"
            alert.informativeText = msg
            alert.runModal()
        }
    }
}

// MARK: - 悬浮窗控制器
// 平时贴右侧吸附为一个迷你药丸，点击展开为紧凑玻璃面板，鼠标离开 8 秒后自动收起。

final class PanelController: NSObject {
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
    }

    private let panel: FloatingPanel
    private let effect = GlassSurface()
    private let titleLabel = NSTextField(labelWithString: "⏳")
    private let rowsContainer = NSView()
    private let pillLabel = NSTextField(labelWithString: "")
    private let pillHoverOutline = PillHoverOutline()
    private let headerView = NSStackView()

    private var currentIds: [String] = []
    private var editingId: String?
    private weak var activeInlineView: InlineEditView?
    private var autoItems: [SubItem] = []
    private var refreshing = false
    private var hiddenByUser = false
    private var tickCount = 0
    /// deadline 驱动的窗口滚动：只有跨过下一个重置节点才碰 Store，杜绝每秒空转遍历
    private var rollDeadline: Date = .distantPast   // 启动首次 tick 必滚（补睡眠/离线期间）
    /// dataVersion 驱动的重建：条目集合没变就不重排、不重建
    private var lastSeenDataVersion = -1
    /// 已弹过 5 小时临界弹窗的条目（id@到期瞬间）：同一到期只弹一次，重启后仍在 5h 内会再弹一次
    private var alertedKeys = Set<String>()
    private var statusItem: NSStatusItem?
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
        if loadOfficialData { refreshData() }
    }

    // MARK: 面板与位置

    private func setupPanel() {
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)

        let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        if let f = screen?.visibleFrame {
            panel.setFrame(NSRect(x: f.maxX - Metrics.dockMargin - Metrics.pillWidth, y: f.maxY - 170,
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
        headerView.addArrangedSubview(miniBtn("⟳", #selector(refreshClicked)))
        headerView.addArrangedSubview(miniBtn("⚙", #selector(openSettings)))
        headerView.addArrangedSubview(miniBtn("✕", #selector(hideClicked)))

        pillLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        pillLabel.alignment = .center
        pillLabel.lineBreakMode = .byClipping

        container = PanelContainerView()
        container.addSubview(effect)
        container.addSubview(headerView)
        container.addSubview(rowsContainer)
        container.addSubview(pillLabel)
        pillHoverOutline.alphaValue = 0
        container.addSubview(pillHoverOutline)
        panel.contentView = container

        container.onMouseEnter = { [weak self] in
            guard let self else { return }
            self.cancelAutoCollapse()
            // 收起态仅提亮边缘，文字和玻璃始终保持同一位置。
            if Store.shared.state.panelCollapsed { self.setPillHover(true) }
        }
        container.onMouseExit = { [weak self] in
            guard let self else { return }
            self.scheduleAutoCollapse()
            if Store.shared.state.panelCollapsed { self.setPillHover(false) }
        }
        container.onBackgroundClick = { [weak self] in self?.pillClicked() }

        effect.menu = buildContextMenu()
    }

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

    /// 以「右上角」为锚点调整窗口尺寸并手动布局
    private func updateFrame(expanded: Bool, contentH: CGFloat) {
        let prev = panel.frame
        let topY = prev.maxY
        let width = expanded ? Metrics.expandedWidth : Metrics.pillWidth
        let height = expanded ? contentH : Metrics.pillHeight
        let rightX = expanded ? panel.screen?.visibleFrame.maxX ?? prev.maxX : prev.maxX
        let anchorRight = expanded ? rightX - Metrics.dockMargin : rightX
        panel.setFrame(NSRect(x: anchorRight - width, y: topY - height, width: width, height: height),
                       display: true, animate: false)
        layoutChrome()
    }

    private func layoutChrome() {
        guard let b = panel.contentView?.bounds else { return }
        let collapsed = Store.shared.state.panelCollapsed
        pillHoverOutline.frame = b
        pillHoverOutline.isHidden = !collapsed
        if !collapsed { pillHoverOutline.alphaValue = 0 }
        effect.frame = b
        effect.cornerRadius = collapsed ? 9 : 18
        effect.needsDisplay = true

        if collapsed {
            headerView.isHidden = true
            rowsContainer.isHidden = true
            pillLabel.isHidden = false
            pillLabel.stringValue = pillText()
            pillLabel.toolTip = Self.upcomingTooltip(allItems)
            refitPill()
        } else {
            pillLabel.isHidden = true
            headerView.isHidden = false
            rowsContainer.isHidden = false
            headerView.frame = NSRect(x: Metrics.padSide,
                                      y: b.height - Metrics.padTop - Metrics.headerH,
                                      width: b.width - Metrics.padSide * 2,
                                      height: Metrics.headerH)
            let rowsTop = b.height - Metrics.padTop - Metrics.headerH - 3
            let w = b.width - Metrics.padSide * 2
            rowsContainer.frame = NSRect(x: Metrics.padSide, y: Metrics.padBottom,
                                         width: w, height: max(rowsTop - Metrics.padBottom, 0))
            // 逐条摆放（自上而下）：分区标题 14 / 行 24 / 内联编辑卡用固有高度，间距 1
            var y = rowsContainer.bounds.height
            for v in rowsContainer.subviews {
                let h: CGFloat
                if v is SectionHeaderView {
                    h = Metrics.sectionH
                } else if let inline = v as? InlineEditView {
                    h = inline.intrinsicContentSize.height
                } else {
                    h = Metrics.rowH
                }
                y -= h
                v.frame = NSRect(x: 0, y: y, width: w, height: h)
                y -= Metrics.spacing
            }
        }
    }

    private func pillText() -> String {
        guard let nearest = visibleItems.first else { return "⏳" }   // 归档条目不占据药丸
        let text = Fmt.countdownShort(until: nearest.expiresAt)
        pillLabel.textColor = RowView.urgencyColor(nearest, now: Date())
        return text
    }

    /// 药丸文本布局：可用宽仅 54−12=42pt，放不下就按 0.5pt 阶梯缩小字号（下限 6.5pt）防硬裁剪。
    /// 宽度用 label 自身 intrinsicContentSize 度量——含真实字体度量与字距，比 NSAttributedString
    /// 估算更可靠（「16时12分」估算 45.2 vs 实际 45.5，估算贴边就会漏缩）。
    private func refitPill() {
        let avail = container.bounds.width - 12
        var size = Metrics.pillFontSize
        while size > Metrics.pillMinFontSize {
            pillLabel.font = .monospacedDigitSystemFont(ofSize: size, weight: .medium)
            pillLabel.invalidateIntrinsicContentSize()
            if ceil(pillLabel.intrinsicContentSize.width) <= avail { break }
            size -= 0.5
        }
        pillLabel.font = .monospacedDigitSystemFont(ofSize: size, weight: .medium)
        pillLabel.sizeToFit()
        let b = container.bounds
        pillLabel.frame = NSRect(x: 6, y: (b.height - pillLabel.frame.height) / 2,
                                 width: b.width - 12, height: pillLabel.frame.height)
    }

    // MARK: 收起 / 展开

    func applyCollapsed(_ collapsed: Bool) {
        Store.shared.state.panelCollapsed = collapsed
        Store.shared.save()
        rebuildAll()
        if !collapsed { Motion.reveal(rowsContainer) }   // 展开时内容虚化渐入
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
        guard collapseSuppressor.shouldSchedule else { return }   // 说明弹窗/编辑期间抑制
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
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "⏳"
        statusItem?.button?.toolTip = Self.upcomingTooltip(allItems)
        let menu = NSMenu()
        menu.addItem(withTitle: "显示 / 隐藏悬浮窗", action: #selector(toggleVisible), keyEquivalent: "")
        menu.addItem(withTitle: "设置后台…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "立即刷新官方数据", action: #selector(refreshClicked), keyEquivalent: "r")
        menu.addItem(.separator())
        let launch = NSMenuItem(title: "常驻（开机自启+崩溃自动拉起）", action: #selector(toggleLaunch), keyEquivalent: "")
        launch.state = Resident.isInstalled() ? .on : .off
        menu.addItem(launch)
        menu.addItem(withTitle: "打开数据文件夹", action: #selector(openDataFolder), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出（常驻中会自动重启）", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
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
        return menu
    }

    // MARK: 数据

    private var allItems: [SubItem] {
        (autoItems + Store.shared.manualItems).sorted { $0.expiresAt < $1.expiresAt }
    }

    /// 面板/药丸/菜单栏展示口径：过滤掉已自动归档的条目（仍在库中，设置后台可见可清理）
    private var visibleItems: [SubItem] {
        allItems.filter { !$0.isArchived }
    }

    func refreshData() {
        guard !refreshing else { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = ReaderEngine.refreshAll()
            DispatchQueue.main.async {
                guard let self else { return }
                let dismissed = Set(self.Store_dismissedAuto())
                self.autoItems = result.items.filter { !dismissed.contains($0.id) }
                self.refreshing = false
                self.rebuildAll()
            }
        }
    }

    static func upcomingTooltip(_ items: [SubItem]) -> String {
        let now = Date()
        let top = items.sorted { $0.expiresAt < $1.expiresAt }.prefix(3)
        guard !top.isEmpty else { return "暂无到期记录" }
        let lines = top.map { "• \($0.name)：\(Fmt.countdownShort(until: $0.expiresAt, now: now))" }
        return "最近到期\n" + lines.joined(separator: "\n")
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

        // 5 小时临界弹窗：固定在剩 5 小时时弹一次（每个到期瞬间只弹一次，内存去重）。
        // 多条同时临期合并为一个居中模态，弹到屏幕正中央让人无法忽略。
        let due = items.filter {
            let remain = $0.expiresAt.timeIntervalSince(now)
            return remain > 0 && remain <= 5 * 3600
                && !alertedKeys.contains("\($0.id)@\($0.expiresAt.timeIntervalSince1970)")
        }
        if !due.isEmpty {
            due.forEach { alertedKeys.insert("\($0.id)@\($0.expiresAt.timeIntervalSince1970)") }
            presentExpirationAlert(due, now: now)
        }

        if !Store.shared.state.panelCollapsed {
            for case let row as RowView in rowsContainer.subviews {
                if let item = row.item { row.configure(item, now: now) }
            }
        } else if !items.isEmpty {
            let nearest = items[0]
            let text = Fmt.countdownShort(until: nearest.expiresAt, now: now)
            if text != pillLabel.stringValue {
                let color = RowView.urgencyColor(nearest, now: now)
                if nearest.expiresAt.timeIntervalSince(now) < 120 {
                    // 最后两分钟文本每秒变化，直接更新避免持续闪烁
                    pillLabel.stringValue = text
                    pillLabel.textColor = color
                    refitPill()
                } else {
                    Motion.crossfadeText(pillLabel) {
                        self.pillLabel.stringValue = text
                        self.pillLabel.textColor = color
                        self.refitPill()
                    }
                }
            }
        }

        // 菜单栏实时倒计时（借鉴 Claude-Code-Usage-Monitor 的 title-format 思路）；文本没变不写
        if let btn = statusItem?.button {
            let title = items.first.map { "⏳ " + Fmt.countdownShort(until: $0.expiresAt, now: now) } ?? "⏳"
            if btn.title != title { btn.title = title }
        }

        // 条目集合有变才重建行、刷新 tooltip；顺带把新增/编辑窗口纳入滚动 deadline
        if Store.shared.dataVersion != lastSeenDataVersion {
            lastSeenDataVersion = Store.shared.dataVersion
            statusItem?.button?.toolTip = Self.upcomingTooltip(items)
            rebuildIfNeeded(items: items)
            if let next = Store.shared.nextRollInstant() {
                rollDeadline = min(rollDeadline, next)
            }
        }

        tickCount += 1
        // 自愈：窗口不可见（被拖出屏幕外/切到别的空间）时，吸附回主屏右上角再拉起。
        // makeKeyAndOrderFront 救不回位于屏幕外的窗口，必须先把位置搬回可视区。
        if tickCount % 30 == 0 {
            if let btn = statusItem?.button { btn.toolTip = Self.upcomingTooltip(items) }
            if !hiddenByUser && !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
                NSLog("AR: 面板不在屏上，自动恢复显示")
                let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
                if let f = screen?.visibleFrame {
                    panel.setFrameOrigin(NSPoint(x: f.maxX - Metrics.dockMargin - panel.frame.width, y: f.maxY - 170))
                    UserDefaults.standard.removeObject(forKey: "panelOrigin")   // 丢弃离屏的旧坐标
                }
                panel.orderFrontRegardless()
                Motion.reveal(panel)
            }
        }
    }

    /// 临期弹窗：NSAlert 模态默认弹在屏幕正中央；.common 模式下 tick 心跳不中断。
    /// 弹窗本身不是提醒渠道，而是把「快到期」这件事顶到眼前——面板常驻右角易被忽视。
    private func presentExpirationAlert(_ due: [SubItem], now: Date) {
        let sorted = due.sorted { $0.expiresAt < $1.expiresAt }
        let list = sorted
            .map { "• \($0.name)——剩 \(Fmt.countdown(until: $0.expiresAt, now: now))（\(Fmt.absTime($0.expiresAt))）" }
            .joined(separator: "\n")
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = sorted.count == 1 ? "「\(sorted[0].name)」5 小时内到期" : "\(sorted.count) 项额度 5 小时内到期"
        alert.informativeText = list + "\n\n过期后额度即清零，请尽快安排使用。"
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func rebuildIfNeeded(items: [SubItem]) {        let ids = items.map(\.id)
        guard ids != currentIds else {
            let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            for case let row as RowView in rowsContainer.subviews {
                if let id = row.item?.id, let fresh = byID[id] {
                    row.updateItem(fresh)
                    row.configure(fresh, now: Date())
                }
            }
            return
        }
        rebuildAll()
    }

    private func makeInlineEditor(_ item: SubItem) -> NSView? {
        guard !item.isAuto else { return nil }
        let editor = InlineEditView(item: item)
        activeInlineView = editor
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
                entries.append((row, Metrics.rowH))
                // 点击条目展开内联编辑卡（README 承诺的行下编辑入口）
                if editingId == item.id, let editor = makeInlineEditor(item) {
                    entries.append((editor, editor.intrinsicContentSize.height))
                }
            }
        }

        section("额度窗口", autoItems.filter { $0.kind == .window })
        section("订阅", autoItems.filter { $0.kind == .subscription })
        section("手动记录", Store.shared.manualItems.filter { !$0.isArchived })
        if entries.isEmpty {
            let hint = NSTextField(labelWithString: "暂无条目，点 ＋ 添加")
            hint.font = .systemFont(ofSize: 9)
            hint.textColor = .tertiaryLabelColor
            hint.frame = NSRect(x: 2, y: 0, width: 180, height: 20)
            entries.append((hint, 20))
        }
        return entries
    }

    /// 重建面板内容。animate=true 时内联编辑卡波浪展开/收起、其余行平滑让位
    /// （用户主动操作传入 true；每秒数据刷新走默认 false，保持同步、不动画）
    private func rebuildAll(animate: Bool = false) {
        let entries = buildEntries()
        currentIds = entries.compactMap { ($0.view as? RowView)?.item?.id }
        rowsContainer.subviews.forEach { $0.removeFromSuperview() }
        for (view, _) in entries {
            rowsContainer.addSubview(view)
        }
        let contentH = Metrics.padTop + Metrics.headerH + 3
            + entries.reduce(0) { $0 + $1.height + Metrics.spacing }
            + Metrics.padBottom

        // 高度/行位变化统一在此生效：animate 时走隐式动画（卡片波浪展开、下方行平滑让位）
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.revealDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = animate
            self.updateFrame(expanded: !Store.shared.state.panelCollapsed, contentH: contentH)
        }, completionHandler: nil)

        // 每次点开内联编辑卡都虚化渐入（blur-in），与全局点击交互语言一致
        if animate {
            for case let v as InlineEditView in rowsContainer.subviews {
                Motion.reveal(v)
            }
        }

        if Store.shared.state.panelCollapsed {
            pillLabel.stringValue = pillText()
        }
    }

    // MARK: 动作

    @objc private func moved() {
        // NSValue 不是合法的 plist 类型，直接写入会在 CFPrefs 校验时抛异常崩溃
        let o = panel.frame.origin
        UserDefaults.standard.set([Double(o.x), Double(o.y)], forKey: "panelOrigin")
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
            collapseSuppressor.begin()
            let alert = NSAlert()
            alert.messageText = item.name
            alert.informativeText = "来源：\(item.source) 官方本地数据\n到期：\(Fmt.absTime(item.expiresAt))\n\(item.note)\n（官方数据每次刷新自动更新，如需自定义请手动添加）"
            alert.runModal()
            if collapseSuppressor.end(cursorInsidePanel: isCursorInsidePanel()) {
                scheduleAutoCollapse()
            }
            return
        }
        editingId = (editingId == item.id) ? nil : item.id   // 再点一次收起
        rebuildAll(animate: true)
    }

    /// 光标（屏幕坐标）是否位于面板**整个内容区**（含 header 工具条与内边距，
    /// 与 PanelContainerView 追踪区范围一致）。仅用 rect 版系统转换，避免点/矩形重载歧义
    private func isCursorInsidePanel() -> Bool {
        guard let content = panel.contentView, let win = content.window else { return false }
        let boundsInWindow = content.convert(content.bounds, to: nil)
        let inScreen = win.convertToScreen(boundsInWindow)
        return inScreen.contains(NSEvent.mouseLocation)
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
            guard DeleteConfirm.run(item, verb: "隐藏",
                                    hint: "官方数据本地仍会更新，点 ⟳ 刷新官方数据即可恢复显示") else { return }
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
                switch alert.runModal() {
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
        guard DeleteConfirm.run(item, hint: "手动录入的信息删除后不可恢复，需要重新录入") else { return }
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
            alert.runModal()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let editor = EditorSheetController(item: item, isNew: isNew)
        editor.window?.isReleasedWhenClosed = false
        activeEditors.append(editor)   // 保活：否则控制器释放后按钮 target 变 nil
        editor.onSave = { [weak self] savedItem, previousExpiry, weeklyAnchor in
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
                self?.activeEditors.removeAll { $0 === editor }
            }
            if case .savedWithAlignFailure(let failures) = result {
                // 明确哪些关联未同步；证据留存于 Store.lastAlignmentFailures，恢复方案另行处理
                EditorSheetController.lastSaveFailureMessage =
                    "已保存，但以下关联未能同步：\(failures.joined(separator: "、"))"
            }
            return result.saved
        }
        editor.onDelete = { [weak self] id in
            guard let it = Store.shared.manualItems.first(where: { $0.id == id }),
                  DeleteConfirm.run(it, hint: "手动录入的信息删除后不可恢复，需要重新录入") else { return false }
            Store.shared.deleteManualWithDerived(id)
            deleted()
            self?.activeEditors.removeAll { $0 === editor }
            return true
        }
        parent.beginSheet(editor.window!)
        Motion.reveal(editor.window!.contentView!)   // 每次点开表单都虚化渐入
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        ensureSettings().showWindow(nil)
    }

    func openSettingsWindow() {
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

    @objc private func hideClicked() { hiddenByUser = true; panel.orderOut(nil) }

    @objc private func toggleVisible() {
        if panel.isVisible { hideClicked() } else { hiddenByUser = false; panel.orderFrontRegardless() }
    }

    @objc private func toggleLaunch() {
        let nowOn = Resident.toggle()
        Store.shared.state.launchAtLogin = nowOn
        Store.shared.save()
    }

    @objc private func openDataFolder() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        NSWorkspace.shared.open(base.appendingPathComponent("AI到期提醒", isDirectory: true))
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func showPanel() {
        hiddenByUser = false
        applyCollapsed(Store.shared.state.panelCollapsed)
        panel.makeKeyAndOrderFront(nil)
        Motion.reveal(panel)
    }

    // MARK: 自测渲染支持

    var debugContentView: NSView? { panel.contentView }
    /// TestRender 断言用：药丸当前字号（验证长倒计时触发的自适应缩小）
    var debugPillFontSize: CGFloat { pillLabel.font?.pointSize ?? 0 }
    func debugShowInlineEditor() {
        if let first = Store.shared.manualItems.first(where: { !$0.isAuto }) {
            editingId = first.id
        }
        rebuildAll()
    }
    func debugSetExpanded(_ expanded: Bool) {
        Store.shared.state.panelCollapsed = !expanded
        rebuildAll()
    }
}
