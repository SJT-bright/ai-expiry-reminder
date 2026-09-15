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
            nameLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: 7),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: countdownLabel.leadingAnchor, constant: -8),

            countdownLabel.trailingAnchor.constraint(equalTo: deleteBtn.leadingAnchor, constant: -4),
            countdownLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),

            deleteBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            deleteBtn.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            deleteBtn.widthAnchor.constraint(equalToConstant: 16),

            subLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            subLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            subLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor),

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

    /// 悬停反馈：行浮起（轻微放大）+ 背景高亮；移出落下
    override func mouseEntered(with event: NSEvent) {
        Motion.float(self, on: true, scale: 1.04)
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
                     "来源：\(item.isAuto ? "官方本地数据" : "手动添加") · 提前\(Int(item.alertBeforeMinutes))分钟提醒"]
        if let used = item.usedPercent {
            var pace = "额度剩余 \(Int(100 - used))%"
            let delta = paceDelta(item, now: now)
            if delta >= 15 { pace += " · ⚡消耗快于时间进度" }
            lines.append(pace)
        }
        if !item.note.isEmpty { lines.append(item.note) }
        return lines.joined(separator: "\n")
    }

    /// 红色规则：仅剩 24 小时内标红；额度用尽（剩余 0%）时改为白色提示，其余全绿
    static func urgencyColor(_ item: SubItem, now: Date) -> NSColor {
        let remain = item.expiresAt.timeIntervalSince(now)
        if let used = item.usedPercent, used >= 100 {
            return NSColor(white: 0.92, alpha: 1)                                // 额度耗尽：白色
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

// MARK: - 添加 / 编辑表单（Sheet，玻璃质感）

final class EditorSheetController: NSWindowController {
    /// 返回 false = 写入失败（表单保持打开、输入保留）
    var onSave: ((SubItem) -> Bool)?
    var onSaveMany: (([SubItem]) -> Bool)?
    /// 返回 true = 已确认删除（此时表单应关闭）；false = 用户取消（表单保持打开）
    var onDelete: ((String) -> Bool)?

    /// 自测开关：关闭后保存失败不弹系统弹窗（TestRender 断言表单行为时使用）
    static var showsSaveFailureAlerts = true
    /// 最近一次保存失败的提示文案（含部分失败）；自测断言用
    static var lastSaveFailureMessage: String?
    /// 自测注入点：非 nil 时替代真实的周重置同步（TestRender 验证部分失败边界）
    var quotaResetSyncOverride: ((SubItem, Bool, Date) -> Bool)?

    private var item: SubItem
    private let isNew: Bool

    private let nameField = NSTextField(string: "")
    private let vendorCombo = NSComboBox()
    private let kindPopup = NSPopUpButton()
    private let datePicker = NSDatePicker()       // 一行式日期时间（分段点击键入）
    private let repeatField = NSTextField(string: "5")
    private let alertField = NSTextField(string: "60")
    private let alertStepper = NSStepper()
    private let noteField = NSTextField(string: "")
    private let weeklyCheck = NSButton(checkboxWithTitle: "",
                                       target: nil,
                                       action: nil)
    private let resetCheck = NSButton(checkboxWithTitle: "",
                                      target: nil,
                                      action: nil)
    private let resetModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let resetParamField = NSTextField(string: "")
    private let nextPreviewLabel = NSTextField(labelWithString: "")
    private let vendorHintLabel = NSTextField(labelWithString: "")
    private let purchasePicker = NSDatePicker()
    private let inferenceLabel = NSTextField(labelWithString: "")
    private let resetPicker = NSDatePicker()
    private weak var formGrid: NSGridView?
    private var lastExpiry: Date?

    init(item: SubItem, isNew: Bool) {
        self.item = item
        self.isNew = isNew
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 392),
                           styleMask: [.titled],
                           backing: .buffered, defer: false)
        Glass.glassWindow(win)
        super.init(window: win)
        buildForm()
        load()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildForm() {
        nameField.placeholderString = "例：Grok 重置卡 / ChatGPT Plus 年付"
        vendorCombo.addItems(withObjectValues: ["OpenAI", "Anthropic", "xAI", "Google", "中转站", "其他"])
        vendorCombo.completes = true
        kindPopup.addItems(withTitles: ["订阅 / 会员 / 重置卡到期", "周期额度窗口（到期自动滚动）"])
        kindPopup.target = self
        kindPopup.action = #selector(kindChanged)
        // 一行式日期时间：分段点击直接键入数字，方向键微调，无需删除键
        datePicker.datePickerElements = [.yearMonthDay, .hourMinute]
        datePicker.datePickerStyle = .textField
        datePicker.target = self
        datePicker.action = #selector(expiryChanged)
        repeatField.placeholderString = "周期小时数，例：5"
        alertField.placeholderString = "提前多少分钟提醒"
        noteField.placeholderString = "备注（可选）"
        weeklyCheck.title = "按周划分额度提醒（每周一条，到期分别提醒）"
        weeklyCheck.font = NSFont.systemFont(ofSize: 11)
        weeklyCheck.target = self
        weeklyCheck.action = #selector(weeklyChanged)

        // 周额度重置：独立于到期日。模式决定模型——滚动(锚点+N小时) / 日历锚定(固定月日·星期) / 订阅日锚定月
        resetCheck.title = "周期重置 · 独立于到期日"
        resetCheck.font = NSFont.systemFont(ofSize: 11)
        resetCheck.target = self
        resetCheck.action = #selector(resetToggled)
        resetModePopup.addItems(withTitles: ["滚动 7 天", "滚动 30 天（1个月）", "滚动 60 天（2个月）", "滚动 90 天（3个月）", "滚动 180 天", "滚动 365 天", "每月固定日", "每周固定星期", "订阅日锚定月"])
        resetModePopup.font = .systemFont(ofSize: 10.5)
        resetModePopup.target = self
        resetModePopup.action = #selector(resetModeChanged)
        resetParamField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        resetParamField.placeholderString = "17"
        resetParamField.target = self
        resetParamField.action = #selector(resetParamChanged)
        nextPreviewLabel.font = .systemFont(ofSize: 9.5)
        nextPreviewLabel.textColor = .secondaryLabelColor
        let resetRow1 = NSStackView(views: [resetCheck, resetModePopup])
        resetRow1.orientation = .horizontal
        resetRow1.spacing = 8
        let resetRow2 = NSStackView(views: [resetPicker, resetParamField, nextPreviewLabel])
        resetRow2.orientation = .horizontal
        resetRow2.spacing = 8
        // 购买时间：推断重置模型的关键输入
        let purchaseLabel = NSTextField(labelWithString: "购买:")
        purchaseLabel.font = .systemFont(ofSize: 10)
        purchaseLabel.textColor = .secondaryLabelColor
        purchasePicker.datePickerElements = [.yearMonthDay, .hourMinute]
        purchasePicker.datePickerStyle = .textField
        purchasePicker.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        purchasePicker.target = self
        purchasePicker.action = #selector(purchaseChanged)
        let purchaseRow = NSStackView(views: [purchaseLabel, purchasePicker])
        purchaseRow.orientation = .horizontal
        purchaseRow.spacing = 6
        inferenceLabel.font = .systemFont(ofSize: 9.5)
        inferenceLabel.textColor = .systemTeal
        inferenceLabel.maximumNumberOfLines = 2
        let resetRow = NSStackView(views: [resetRow1, resetRow2, purchaseRow, inferenceLabel])
        resetRow.orientation = .vertical
        resetRow.alignment = .leading
        resetRow.spacing = 4

        // 供应商重置规则提示（调研知识库，来源见 RESEARCH.md）
        vendorHintLabel.font = .systemFont(ofSize: 9.5)
        vendorHintLabel.textColor = .tertiaryLabelColor
        vendorHintLabel.maximumNumberOfLines = 2
        vendorHintLabel.setAccessibilityIdentifier("vendorHint")
        vendorCombo.target = self
        vendorCombo.action = #selector(vendorChanged)
        updateVendorHint()

        // 快捷调整：一键设到期时间
        func quickBtn(_ title: String, _ seconds: TimeInterval) -> NSButton {
            let b = HoverEffectButton(title: title, target: self, action: #selector(quickSet(_:)))
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.tag = Int(seconds)
            return b
        }
        let quickRow = NSStackView(views: [quickBtn("＋1小时", 3600),
                                           quickBtn("＋1天", 86400),
                                           quickBtn("＋1周", 7 * 86400),
                                           quickBtn("＋30天", 30 * 86400)])
        quickRow.orientation = .horizontal
        quickRow.spacing = 6

        // 提前提醒：输入框 + 步进器（点击 ±15 分钟）
        alertStepper.minValue = 0
        alertStepper.maxValue = 4320
        alertStepper.increment = 15
        alertStepper.target = self
        alertStepper.action = #selector(stepperChanged)
        let alertRow = NSStackView(views: [alertField, alertStepper])
        alertRow.orientation = .horizontal
        alertRow.spacing = 4

        let labels = ["名称", "供应商", "厂商规则", "类型", "周额度重置", "划分周额度", "到期时间", "快捷调整", "周期(小时)", "提前提醒(分)", "备注"]
        let fields: [NSView] = [nameField, vendorCombo, vendorHintLabel, kindPopup, resetRow, weeklyCheck, datePicker, quickRow, repeatField, alertRow, noteField]
        let rows: [[NSView]] = zip(labels, fields).map { label, field in
            let l = NSTextField(labelWithString: label)
            l.font = .systemFont(ofSize: 11)
            return [l, field]
        }
        let grid = NSGridView(views: rows)
        formGrid = grid
        grid.column(at: 0).xPlacement = NSGridCell.Placement.trailing
        grid.column(at: 0).width = 80
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false

        let deleteBtn = HoverEffectButton(title: "删除", target: self, action: #selector(deleteClicked))
        deleteBtn.contentTintColor = .systemRed
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

            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 32),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            btnRow.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 12),
            btnRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            btnRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            btnRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
    }

    private func load() {
        nameField.stringValue = item.name
        vendorCombo.stringValue = item.vendor
        kindPopup.selectItem(at: item.kind == .window ? 1 : 0)
        datePicker.dateValue = item.expiresAt
        lastExpiry = item.expiresAt
        if let h = item.repeatHours { repeatField.stringValue = String(format: "%g", h) }
        alertField.stringValue = String(format: "%g", item.alertBeforeMinutes)
        noteField.stringValue = item.note
        weeklyCheck.state = .off
        // 按伴生窗口的规则回填模式；新增默认滚动 7 天（首次重置 = 到期+7天）
        if let comp = Store.shared.manualItems.first(where: { $0.id == Self.quotaResetId(for: item.id) }) {
            resetCheck.state = .on
            switch comp.resetRule {
            case .calendarMonth:
                resetModePopup.selectItem(at: 6)
                resetParamField.stringValue = String(comp.resetParam ?? 1)
            case .calendarWeek:
                resetModePopup.selectItem(at: 7)
                resetParamField.stringValue = String(comp.resetParam ?? 1)
            case .anchorMonth:
                resetModePopup.selectItem(at: 8)
                resetParamField.stringValue = String(comp.resetParam ?? 1)
            case .rolling, nil:
                // 滚动档位：按 repeatHours 反推天数（7/30/60/90/180/365），未知就近兜底
                let days = Int((comp.repeatHours ?? 168) / 24)
                resetModePopup.selectItem(at: Self.rollingDayOptions.firstIndex(of: days) ?? 0)
                resetPicker.dateValue = comp.expiresAt
            }
        } else {
            resetCheck.state = .off
            resetModePopup.selectItem(at: 0)
            resetPicker.dateValue = item.expiresAt.addingTimeInterval(168 * 3600)
        }
        updateResetControls()
        updateVendorHint()
        purchasePicker.dateValue = item.expiresAt.addingTimeInterval(-28 * 86400)
        kindChanged()
    }

    @objc private func kindChanged() {
        let isWindow = kindPopup.indexOfSelectedItem == 1
        // 行号见 buildForm 顺序：2 = 厂商提示，4 = 周额度重置，5 = 划分周额度，8 = 周期(小时)
        formGrid?.row(at: 8).isHidden = !isWindow
        formGrid?.row(at: 4).isHidden = isWindow
        formGrid?.row(at: 5).isHidden = isWindow
    }

    @objc private func vendorChanged() {
        updateVendorHint()
    }

    /// 供应商 → 调研知识库提示（详见 RESEARCH.md）
    private func updateVendorHint() {
        vendorHintLabel.stringValue = VendorResetKnowledge.hint(for: vendorCombo.stringValue) ?? ""
    }

    @objc private func resetModeChanged() {
        updateResetControls()
    }

    @objc private func resetParamChanged() {
        updateNextPreview()
    }

    /// 滚动档位（弹窗 index 0-5）对应的天数；index ≥ 档位数 = 日历模型
    static let rollingDayOptions: [Int] = [7, 30, 60, 90, 180, 365]
    private var isCalendarMode: Bool { resetModePopup.indexOfSelectedItem >= Self.rollingDayOptions.count }

    /// 按模式切换输入控件：滚动=锚点日期；日历=单个数字参数（月日/星期几）+ 下次重置预览
    private func updateResetControls() {
        let mode = resetModePopup.indexOfSelectedItem
        resetPicker.isHidden = isCalendarMode       // 滚动档位用锚点日期
        resetParamField.isHidden = !isCalendarMode  // 日历档位用数字参数
        nextPreviewLabel.isHidden = !isCalendarMode
        resetParamField.placeholderString = mode == 7 ? "星期几（1=周一…7=周日）" : "几号（1-31）"
        updateNextPreview()
    }

    /// 「一个数字」交互：输入 17 = 每月 17 号 00:00 重置；输入 1 = 每周一 00:00 重置
    private func updateNextPreview() {
        let mode = resetModePopup.indexOfSelectedItem
        guard isCalendarMode else {
            nextPreviewLabel.stringValue = "自下次重置起，每 \(Self.rollingDayOptions[mode]) 天滚动一轮"
            return
        }
        let rule: ResetRule? = mode == 6 ? .calendarMonth : mode == 7 ? .calendarWeek : .anchorMonth
        let param = sanitizedResetParam(mode: mode)
        var probe = item
        probe.resetRule = rule
        probe.resetParam = param
        if let next = probe.nextCalendarReset(after: Date()) {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd 00:00"
            nextPreviewLabel.stringValue = "下次重置：" + f.string(from: next)
        } else {
            nextPreviewLabel.stringValue = "参数无效"
        }
    }

    /// 参数清洗：月日 1-31；星期 1-7（1=周一）
    private func sanitizedResetParam(mode: Int) -> Int {
        let raw = Int(resetParamField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1
        return mode == 2 ? min(max(raw, 1), 7) : min(max(raw, 1), 31)
    }

    @objc private func weeklyChanged() {
        // 两种周策略互斥：按周划分 = 静态拆分提醒；周额度重置 = 滚动窗口
        if weeklyCheck.state == .on { resetCheck.state = .off }
    }

    @objc private func resetToggled() {
        if resetCheck.state == .on { weeklyCheck.state = .off }
    }

    @objc private func expiryChanged() {
        // 滚动模式（7~365 天）：到期日变化平移重置锚点（与 Store 层 align_reset 一致）；
        // 日历锚定模式（每月N号/每周X/订阅日锚定）独立于到期日，不平移
        if resetModePopup.indexOfSelectedItem < Self.rollingDayOptions.count, let previous = lastExpiry {
            resetPicker.dateValue = resetPicker.dateValue.addingTimeInterval(
                datePicker.dateValue.timeIntervalSince(previous))
        }
        lastExpiry = datePicker.dateValue
        inferFromDates()
    }

    @objc private func purchaseChanged() {
        inferFromDates()
    }

    @objc private func resetDateChanged() {
        inferFromDates()
    }

    /// 三时间（购买/到期/最近重置）自动推断重置模型并应用——用户无需手动选模式
    private func inferFromDates() {
        guard resetCheck.state == .on else { return }
        let result = ResetInference.infer(purchase: purchasePicker.dateValue,
                                          expiry: datePicker.dateValue,
                                          lastReset: resetPicker.dateValue)
        switch result.rule {
        case .calendarMonth: resetModePopup.selectItem(at: 6)
        case .calendarWeek:  resetModePopup.selectItem(at: 7)
        case .anchorMonth:   resetModePopup.selectItem(at: 8)
        case .rolling:
            let days = max(1, result.param ?? 7)
            resetModePopup.selectItem(at: Self.rollingDayOptions.firstIndex(of: days) ?? 0)
        }
        if result.rule == .calendarMonth || result.rule == .calendarWeek || result.rule == .anchorMonth {
            resetParamField.stringValue = String(result.param ?? 1)
        }
        inferenceLabel.stringValue = "已推断：" + result.explain
        updateResetControls()
    }

    /// 快捷按钮始终沿已填写的时间累加，保留原周期。
    @objc private func quickSet(_ sender: NSButton) {
        datePicker.dateValue = datePicker.dateValue.addingTimeInterval(TimeInterval(sender.tag))
        expiryChanged()
    }

    @objc private func stepperChanged() {
        alertField.stringValue = String(Int(alertStepper.doubleValue))
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
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        expiryChanged()
        item.name = name
        item.vendor = vendorCombo.stringValue.isEmpty ? "未分类" : vendorCombo.stringValue
        item.kind = kindPopup.indexOfSelectedItem == 1 ? .window : .subscription
        item.expiresAt = datePicker.dateValue
        item.repeatHours = item.kind == .window ? Double(repeatField.stringValue) : nil
        item.alertBeforeMinutes = Double(alertField.stringValue) ?? 60
        item.note = noteField.stringValue
        item.source = "manual"

        var savedParent: Bool
        if item.kind == .subscription && weeklyCheck.state == .on {
            savedParent = onSaveMany?(item.splitWeekly()) ?? false
        } else {
            savedParent = onSave?(item) ?? false
        }
        Self.lastSaveFailureMessage = nil
        guard savedParent else {
            // 写入失败：表单保持打开、输入原样保留，用户可直接重试
            Self.lastSaveFailureMessage = "保存失败"
            if Self.showsSaveFailureAlerts {
                let alert = NSAlert()
                alert.messageText = "保存失败"
                alert.informativeText = "数据未能写入，表单内容已保留，请重试。"
                alert.runModal()
            }
            return
        }
        // 周额度重置：到期日只管订阅终止；重置节奏由模式决定（滚动 7~365 天 / 日历锚定）
        let mode = resetModePopup.indexOfSelectedItem
        let rule: ResetRule? = mode < Self.rollingDayOptions.count
            ? .rolling
            : mode == 6 ? .calendarMonth : mode == 7 ? .calendarWeek : .anchorMonth
        let param: Int? = mode < Self.rollingDayOptions.count ? Self.rollingDayOptions[mode] : sanitizedResetParam(mode: mode)
        let resetEnabled = item.kind == .subscription && resetCheck.state == .on && weeklyCheck.state != .on
        let hadCompanion = Store.shared.manualItems.contains { $0.id == Self.quotaResetId(for: item.id) }
        let resetSaved = quotaResetSyncOverride?(item, resetEnabled, resetPicker.dateValue)
            ?? syncQuotaReset(parent: item, enabled: resetEnabled, rule: rule, param: param, anchor: resetPicker.dateValue)
        window?.sheetParent?.endSheet(window!)
        if !resetSaved {
            // 部分失败边界：主条目已保存成功，仅派生窗口未同步；按伴生是否存在给出准确指引
            Self.lastSaveFailureMessage =
                resetEnabled
                    ? (hadCompanion
                       ? "订阅已保存，但周额度重置时间未能更新（保持原值）。请重新打开该条目并再次保存以重试。"
                       : "订阅已保存，但周额度重置未能启用：请重新打开该条目、勾选周期重置并保存。")
                    : "订阅已保存，但旧的周额度重置窗口移除失败"
        }
        // 汇总部分失败（闭包内对齐失败 / 派生窗口同步失败）并统一反馈
        if let msg = Self.lastSaveFailureMessage, Self.showsSaveFailureAlerts {
            let alert = NSAlert()
            alert.messageText = "部分保存失败"
            alert.informativeText = msg
            alert.runModal()
        }
    }

    /// 周重置窗口的确定性 id：跟随父订阅，编辑时反查、保存时幂等更新
    static func quotaResetId(for parentID: String) -> String { "qreset:" + parentID }

    /// 生成 / 更新 / 移除与订阅关联的周期重置窗口。返回写入是否成功。
    /// rolling：anchor 为下次重置时间（由 rollManualWindows 按 repeatHours 滚动）；
    /// 日历模型：resetRule/resetParam 决定节点，expiresAt = 下一个未来节点（离线不累积）。
    @discardableResult
    private func syncQuotaReset(parent: SubItem, enabled: Bool, rule: ResetRule?, param: Int?, anchor: Date) -> Bool {
        let cid = Self.quotaResetId(for: parent.id)
        guard enabled else {
            if Store.shared.manualItems.contains(where: { $0.id == cid }) {
                return Store.shared.deleteManual(id: cid)
            }
            return true
        }
        var c: SubItem
        if let existing = Store.shared.manualItems.first(where: { $0.id == cid }) {
            c = existing
        } else {
            c = SubItem.manualDefault(name: "", vendor: parent.vendor)
            c.id = cid
            c.kind = .window
            c.groupID = parent.groupID ?? parent.id
        }
        let calendar = rule == .calendarMonth || rule == .calendarWeek || rule == .anchorMonth
        c.name = parent.name.isEmpty ? "周期重置" : "\(parent.name)·周期重置"
        c.vendor = parent.vendor
        c.alertBeforeMinutes = parent.alertBeforeMinutes
        if calendar, let rule, let param {
            c.resetRule = rule
            c.resetParam = param
            c.repeatHours = nil
            c.expiresAt = c.nextCalendarReset(after: Date()) ?? anchor
            switch rule {
            case .calendarMonth:
                c.note = "「\(parent.name)」每月 \(param) 日 00:00 重置额度，独立于到期日"
            case .calendarWeek:
                let names = ["", "周一", "周二", "周三", "周四", "周五", "周六", "周日"]
                c.note = "「\(parent.name)」每周 \(names[param]) 00:00 重置额度，独立于到期日"
            default:
                c.note = "「\(parent.name)」每月订阅日 00:00 重置额度（订阅日锚定月）"
            }
        } else {
            // 滚动档位：param 即天数（7/30/60/90/180/365），写入 repeatHours 供 rollManualWindows 滚动
            let days = (rule == .rolling ? param : nil) ?? 7
            c.resetRule = .rolling
            c.resetParam = days
            c.repeatHours = Double(days * 24)
            c.expiresAt = anchor
            c.note = "「\(parent.name)」每 \(days) 天额度重置，独立于到期日自动滚动"
        }
        return Store.shared.upsertManual(c).saved
    }
}

// MARK: - 悬浮窗控制器
// 平时贴右侧吸附为一个迷你药丸，点击展开为紧凑玻璃面板，鼠标离开 8 秒后自动收起。

final class PanelController: NSObject {
    private enum Metrics {
        static let expandedWidth: CGFloat = 240
        static let pillWidth: CGFloat = 54
        static let pillHeight: CGFloat = 18
        static let expandedRightMargin: CGFloat = 6
        static let headerH: CGFloat = 16
        static let rowH: CGFloat = 28
        static let sectionH: CGFloat = 14
        static let spacing: CGFloat = 1
        static let padSide: CGFloat = 8
        static let padTop: CGFloat = 5
        static let padBottom: CGFloat = 5
    }

    private let panel: FloatingPanel
    private let effect = GlassSurface()
    private let titleLabel = NSTextField(labelWithString: "⏳")
    private let rowsContainer = NSView()
    private let pillLabel = NSTextField(labelWithString: "")
    private let headerView = NSStackView()

    private var currentIds: [String] = []
    private var editingId: String?
    private weak var activeInlineView: InlineEditView?
    private var autoItems: [SubItem] = []
    private var refreshing = false
    private var tickCount = 0
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
            panel.setFrame(NSRect(x: f.maxX - Metrics.pillWidth, y: f.maxY - 170,
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
        panel.contentView = container

        container.onMouseEnter = { [weak self] in
            guard let self else { return }
            self.cancelAutoCollapse()
            // 收起态：悬停药丸浮起
            if Store.shared.state.panelCollapsed { Motion.float(self.pillLabel, on: true, scale: 1.1) }
        }
        container.onMouseExit = { [weak self] in
            guard let self else { return }
            self.scheduleAutoCollapse()
            if Store.shared.state.panelCollapsed { Motion.float(self.pillLabel, on: false) }
        }
        container.onBackgroundClick = { [weak self] in self?.pillClicked() }

        effect.menu = buildContextMenu()
    }

    /// 以「右上角」为锚点调整窗口尺寸并手动布局
    private func updateFrame(expanded: Bool, contentH: CGFloat) {
        let prev = panel.frame
        let topY = prev.maxY
        let width = expanded ? Metrics.expandedWidth : Metrics.pillWidth
        let height = expanded ? contentH : Metrics.pillHeight
        let rightX = expanded ? panel.screen?.visibleFrame.maxX ?? prev.maxX : prev.maxX
        let anchorRight = expanded ? rightX - Metrics.expandedRightMargin : rightX
        panel.setFrame(NSRect(x: anchorRight - width, y: topY - height, width: width, height: height),
                       display: true, animate: false)
        layoutChrome()
    }

    private func layoutChrome() {
        guard let b = panel.contentView?.bounds else { return }
        let collapsed = Store.shared.state.panelCollapsed
        effect.frame = b
        effect.cornerRadius = collapsed ? 9 : 18
        effect.needsDisplay = true

        if collapsed {
            headerView.isHidden = true
            rowsContainer.isHidden = true
            pillLabel.isHidden = false
            pillLabel.stringValue = pillText()
            pillLabel.toolTip = Self.upcomingTooltip(allItems)
            pillLabel.sizeToFit()
            pillLabel.frame = NSRect(x: 6, y: (b.height - pillLabel.frame.height) / 2,
                                     width: b.width - 12, height: pillLabel.frame.height)
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
        guard let nearest = allItems.first else { return "⏳" }
        let text = Fmt.countdownShort(until: nearest.expiresAt)
        pillLabel.textColor = RowView.urgencyColor(nearest, now: Date())
        return text
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

    func tick() {
        Store.shared.rollManualWindows()
        let now = Date()
        let items = allItems

        if let btn = statusItem?.button {
            btn.toolTip = Self.upcomingTooltip(items)
        }

        // 菜单栏实时倒计时（借鉴 Claude-Code-Usage-Monitor 的 title-format 思路）
        if let btn = statusItem?.button {
            btn.title = items.first.map { "⏳ " + Fmt.countdownShort(until: $0.expiresAt, now: now) } ?? "⏳"
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
                } else {
                    Motion.crossfadeText(pillLabel) {
                        self.pillLabel.stringValue = text
                        self.pillLabel.textColor = color
                    }
                }
            }
        }
        rebuildIfNeeded(items: items)

        tickCount += 1
        // 自愈：窗口不可见（被拖出屏幕外/切到别的空间）时，吸附回主屏右上角再拉起。
        // makeKeyAndOrderFront 救不回位于屏幕外的窗口，必须先把位置搬回可视区。
        if tickCount % 30 == 0, !panel.occlusionState.contains(.visible) {
            NSLog("AR: 面板不在屏上，自动恢复显示")
            let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
            if let f = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: f.maxX - panel.frame.width, y: f.maxY - 170))
                UserDefaults.standard.removeObject(forKey: "panelOrigin")   // 丢弃离屏的旧坐标
            }
            panel.makeKeyAndOrderFront(nil)
            Motion.reveal(panel)
        }
        if tickCount % 10 == 0 { checkAlerts(items: items, now: now) }
    }

    private func rebuildIfNeeded(items: [SubItem]) {
        let ids = items.map(\.id)
        guard ids != currentIds else { return }
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
        section("手动记录", Store.shared.manualItems)
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
        var revealInline = false
        for (view, height) in entries {
            if animate, view is InlineEditView {
                view.wantsLayer = true
                view.alphaValue = 0
                revealInline = true
            }
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
            if revealInline {
                for case let v as InlineEditView in self.rowsContainer.subviews {
                    v.alphaValue = 1
                }
            }
        }, completionHandler: nil)

        if Store.shared.state.panelCollapsed {
            pillLabel.stringValue = pillText()
        }
    }

    // MARK: 预警

    private func checkAlerts(items: [SubItem], now: Date) {
        let outcome = AlertEngine.check(items: items,
                                        knownKeys: Set(Store.shared.state.notifiedKeys),
                                        now: now)
        guard !outcome.fired.isEmpty else { return }
        let msg = AlertEngine.composeMessage(outcome.fired)
        Notifier.post(title: "AI 到期提醒", body: msg)
        Feishu.send(webhook: Store.shared.state.feishuWebhook, text: msg)
        Store.shared.state.notifiedKeys = outcome.newKeys.sorted()
        Store.shared.save()
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
        guard var it = Store.shared.manualItems.first(where: { $0.id == id }) else { return }
        let persisted = it                       // 已持久化的旧值：写失败时行显示回退到此，避免假数据
        it.expiresAt = date
        let result = Store.shared.upsertManual(it)
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
            Notifier.post(title: "已隐藏：\(item.name)",
                          body: "官方数据本地仍会更新，点 ⟳ 刷新官方数据即可恢复显示")
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
        editor.onSave = { [weak self] savedItem in
            let result = Store.shared.upsertManual(savedItem)
            if result.saved {
                saved()
                self?.activeEditors.removeAll { $0 === editor }
            }
            if case .savedWithAlignFailure(let failures) = result {
                // 明确哪些关联未同步；证据留存于 Store.lastAlignmentFailures，恢复方案另行处理
                EditorSheetController.lastSaveFailureMessage =
                    "订阅已保存，但以下关联未能同步：\(failures.joined(separator: "、"))"
            }
            return result.saved
        }
        editor.onSaveMany = { [weak self] savedItems in
            let result = Store.shared.upsertManual(savedItems)
            if result.saved {
                saved()
                self?.activeEditors.removeAll { $0 === editor }
            }
            if case .partialSaved(let written, let failed) = result {
                EditorSheetController.lastSaveFailureMessage =
                    "按周划分部分成员已保存（成功 \(written) 条，失败 \(failed) 条）。失败的成员未写入，请再次保存以补齐。"
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
            Notifier.post(title: "已恢复全部官方条目", body: "之前隐藏的官方数据已重新显示")
        }
        refreshData()
    }

    @objc private func toggleCollapseMenu() {
        applyCollapsed(!Store.shared.state.panelCollapsed)
    }

    @objc private func hideClicked() { panel.orderOut(nil) }

    @objc private func toggleVisible() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    @objc private func toggleLaunch() {
        let nowOn = Resident.toggle()
        Store.shared.state.launchAtLogin = nowOn
        Store.shared.save()
        Notifier.post(title: nowOn ? "已开启常驻" : "已关闭常驻",
                      body: nowOn ? "登录自启，崩溃后自动重启" : "已从登录项移除")
    }

    @objc private func openDataFolder() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        NSWorkspace.shared.open(base.appendingPathComponent("AI到期提醒", isDirectory: true))
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func showPanel() {
        applyCollapsed(Store.shared.state.panelCollapsed)
        panel.makeKeyAndOrderFront(nil)
        Motion.reveal(panel)
    }

    // MARK: 自测渲染支持

    var debugContentView: NSView? { panel.contentView }
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
