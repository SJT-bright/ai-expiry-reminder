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

// MARK: - 液态玻璃

/// 系统液态玻璃（NSGlassEffectView）在本应用里的统一口径。
/// 折射由系统按元素尺寸/圆角算，我们能调的只有 style、cornerRadius、tintColor：
/// · .clear 通透、边缘折射明显（实测能看见背后壁纸的颜色与字形被扭动）；
/// · .regular 偏暗偏实，接近传统毛玻璃——本应用一律用 .clear。
/// 底板着色稳住浅色背景上的白字；列表行透明，直接共享底板的玻璃。
/// 输入框与编辑卡仍使用独立玻璃，承担控件边界。
enum Glass {
    static let reduceTransparency: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency

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
    var cornerRadius: CGFloat = 18 {
        didSet { glass.cornerRadius = cornerRadius }
    }
    /// 胶囊与展开面板共用同一玻璃着色。
    var tint: NSColor? {
        get { glass.tintColor }
        set { glass.tintColor = newValue }
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
    private(set) var item: SubItem?
    var onOpen: ((SubItem) -> Void)?
    var onDelete: ((SubItem) -> Void)?

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
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
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
        commit()
    }

    deinit { removeKeyMonitor() }

    /// 点日期段 → 就地弹月历。先结束编辑把文本落回 cell，程序化回填才生效。
    /// internal：mouseDown 的落点，也是自测驱动月历接线的入口。
    func openCalendar() {
        guard let window else { return }
        let anchor = convert(bounds, to: nil)      // 月历按宿主窗 view 坐标系定位
        window.makeFirstResponder(nil)
        CalendarPickerController.shared.present(initial: date, anchorRect: anchor, in: window) { [weak self] picked in
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
        // hoverScale 降到 1.04：50pt 宽的芯片按全局 1.12 放大会跳得突兀，触感交给高亮层。
        func chip(_ title: String, _ action: Selector,
                  textColor: NSColor = NSColor(white: 1, alpha: 0.88),
                  fill: NSColor = NSColor(white: 1, alpha: 0.08)) -> HoverEffectButton {
            let b = HoverEffectButton(title: title, target: self, action: action)
            b.isBordered = false
            b.hoverScale = 1.04
            b.font = .systemFont(ofSize: 9, weight: .medium)
            b.contentTintColor = textColor
            b.wantsLayer = true
            b.layer?.backgroundColor = fill.cgColor
            b.layer?.cornerRadius = 6
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

    /// 自测开关：关闭后保存失败不弹系统弹窗（TestRender 断言表单行为时使用）
    static var showsSaveFailureAlerts = true
    /// 最近一次保存失败的提示文案（含部分失败）；自测断言用
    static var lastSaveFailureMessage: String?

    private var item: SubItem
    private let isNew: Bool
    private let previousExpiry: Date

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
        // 首次重置锚点缺省 = 下一轮周重置（现在 + 7 天）；订阅剩余不足 7 天时钳到到期时刻。
        // 早先是「到期 + 7 天」，恒晚于到期 → 直接点选该档不改锚点就无法保存。
        firstResetField.setDate(min(item.expiresAt, Date().addingTimeInterval(7 * 86400)))
        firstResetField.onValidChange = { [weak self] _ in self?.inputChanged() }
        expiryField.setDate(item.expiresAt)
        expiryField.onValidChange = { [weak self] _ in self?.inputChanged() }
        previewLabel.font = .systemFont(ofSize: 9.5)
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.maximumNumberOfLines = 3   // 排期 + 建议可占多行
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
    }

    @objc private func deleteClicked() {
        // 仅在真正删除后才关闭表单；用户在确认框点取消时保持表单打开
        if onDelete?(item.id) == true {
            window?.sheetParent?.endSheet(window!)
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
    private var tickCount = 0
    /// deadline 驱动的窗口滚动：只有跨过下一个重置节点才碰 Store，杜绝每秒空转遍历
    private var rollDeadline: Date = .distantPast   // 启动首次 tick 必滚（补睡眠/离线期间）
    /// dataVersion 驱动的重建：条目集合没变就不重排、不重建
    private var lastSeenDataVersion = -1
    /// 已弹过 5 小时临界弹窗的条目（id@到期瞬间）：同一到期只弹一次，重启后仍在 5h 内会再弹一次
    private var alertedKeys = Set<String>()
    private var statusItem: NSStatusItem?
    /// 菜单栏图标下的那份菜单；只为在每次展开前重读常驻勾选态
    private var statusMenu: NSMenu?
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
                self.collapseSuppressor.begin()
                self.cancelAutoCollapse()
            } else if self.collapseSuppressor.end(cursorInsidePanel: self.isCursorInsidePanel()) {
                self.scheduleAutoCollapse()
            }
        }
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
        refreshButton = miniBtn("⟳", #selector(refreshClicked))
        headerView.addArrangedSubview(refreshButton)
        headerView.addArrangedSubview(miniBtn("⚙", #selector(openSettings)))
        headerView.addArrangedSubview(miniBtn("✕", #selector(hideClicked)))

        pillLabel.font = .monospacedDigitSystemFont(ofSize: Metrics.pillFontSize, weight: .semibold)
        pillLabel.alignment = .center
        pillLabel.lineBreakMode = .byClipping
        pillLabel.maximumNumberOfLines = 1
        pillLabel.textColor = .white
        pillLabel.setAccessibilityIdentifier("capsuleCountdown")


        container = PanelContainerView()
        container.addSubview(headerView)
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
        panel.setFrame(NSRect(x: anchorRight - width, y: topY - height, width: width, height: height),
                       display: true, animate: false)
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
            headerView.isHidden = true
            rowsClip.isHidden = true
            pillLabel.isHidden = false
            pillLabel.stringValue = pillText()
            pillLabel.toolTip = Self.upcomingTooltip(visibleItems) + "\n点击展开 · 拖动移动"
            refitPill()
        } else {
            pillLabel.isHidden = true
            headerView.isHidden = false
            rowsClip.isHidden = false
            headerView.frame = NSRect(x: Metrics.padSide,
                                      y: b.height - Metrics.padTop - Metrics.headerH,
                                      width: b.width - Metrics.padSide * 2,
                                      height: Metrics.headerH)
            let rowsTop = b.height - Metrics.padTop - Metrics.headerH - 3
            let w = b.width - Metrics.padSide * 2
            viewportH = max(rowsTop - Metrics.padBottom, 0)
            rowsClip.frame = NSRect(x: Metrics.padSide, y: Metrics.padBottom,
                                    width: w, height: viewportH)
            // 行容器装全部内容并随 scrollOffset 平移，超出视口的部分由 rowsClip 的 layer 裁掉。
            // 行自上而下摆在高 y 区（AppKit y 向上）：offset=0 时容器顶对齐视口顶，
            // offset=max 时容器底对齐视口底。
            let maxOffset = max(0, rowsContentH - viewportH)
            scrollOffset = min(max(scrollOffset, 0), maxOffset)
            rowsContainer.frame = NSRect(x: 0, y: scrollOffset - maxOffset,
                                         width: w, height: max(rowsContentH, viewportH))
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
            layoutScrollIndicator(width: w, viewport: viewportH, content: rowsContentH)
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
        layoutChrome()
    }

    /// 滚动位置指示条：有溢出才显示，拇指长度与位置按可视比例
    private func layoutScrollIndicator(width: CGFloat, viewport: CGFloat, content: CGFloat) {
        let overflow = content - viewport
        guard overflow > 1, viewport > 12 else {
            scrollIndicator.isHidden = true
            return
        }
        scrollIndicator.isHidden = false
        let trackH = viewport - 6
        let thumbH = max(trackH * viewport / content, 28)
        let progress = scrollOffset / overflow
        scrollIndicator.frame = NSRect(x: width - Metrics.scrollIndicatorW - 1,
                                       y: 3 + (trackH - thumbH) * progress,
                                       width: Metrics.scrollIndicatorW,
                                       height: thumbH)
    }

    private func pillText() -> String {
        guard let nearest = visibleItems.first else {
            pillLabel.textColor = .secondaryLabelColor
            return "暂无记录"
        }
        pillLabel.textColor = RowView.urgencyColor(nearest, now: Date())
        return Fmt.countdownShort(until: nearest.expiresAt)
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
        Store.shared.state.panelCollapsed = collapsed
        Store.shared.save()
        if !collapsed { scrollOffset = 0 }   // 每次展开都从顶部开始
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
        statusLaunchItem = launch
        menu.addItem(launch)
        menu.addItem(withTitle: "打开数据文件夹", action: #selector(openDataFolder), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出（常驻中会自动重启）", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        // 菜单只构建一次，勾选态却会在别处被改（设置后台的复选框、命令行 launchctl）。
        // 挂个 delegate 每次展开前重读真实状态，否则菜单一直在说谎。
        menu.delegate = self
        statusMenu = menu
        item.menu = menu
        statusItem = item
    }

    /// 每次展开菜单栏图标前重读常驻真实状态：勾选态会被设置后台、命令行 launchctl 改到别处
    func menuNeedsUpdate(_ menu: NSMenu) {
        statusLaunchItem?.state = Resident.isInstalled() ? .on : .off
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
        setRefreshIndicator(true)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = ReaderEngine.refreshAll()
            DispatchQueue.main.async {
                guard let self else { return }
                let dismissed = Set(self.Store_dismissedAuto())
                self.autoItems = result.items.filter { !dismissed.contains($0.id) }
                self.refreshing = false
                self.setRefreshIndicator(false)
                self.rebuildAll()
            }
        }
    }

    /// ⟳ 刷新反馈：运行中置灰，结束恢复。否则官方数据没变化时点击毫无观感，用户不知道点没点中。
    private func setRefreshIndicator(_ on: Bool) {
        refreshButton?.isEnabled = !on
        refreshButton?.alphaValue = on ? 0.4 : 1
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
        editor.onHeightChanged = { [weak self] in self?.layoutChrome() }
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

    /// 重建面板内容。点击时仅让新出现的编辑卡向前浮出；行和窗口直接落在目标位置。
    /// 新视图从零坐标做隐式 frame 动画会让整列条目从底部重新升起。
    private func rebuildAll(animate: Bool = false) {
        let openingEditor = animate && editingId != nil && editingId != renderedEditingId
        let entries = buildEntries()
        currentIds = entries.compactMap { ($0.view as? RowView)?.item?.id }
        rowsContainer.subviews.forEach { $0.removeFromSuperview() }
        for (view, _) in entries {
            rowsContainer.addSubview(view)
        }
        let contentH = Metrics.padTop + Metrics.headerH + 3
            + entries.reduce(0) { $0 + $1.height + Metrics.spacing }
            + Metrics.padBottom
        rowsContentH = entries.reduce(0) { $0 + $1.height + Metrics.spacing }

        // 新建的行没有可供插值的旧位置；关掉隐式动画，避免每次点击都从容器原点上升。
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            self.updateFrame(expanded: !Store.shared.state.panelCollapsed, contentH: contentH)
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

    // MARK: 动作

    @objc private func moved() {
        // NSValue 不是合法的 plist 类型，直接写入会在 CFPrefs 校验时抛异常崩溃
        let o = panel.frame.origin
        UserDefaults.standard.set([Double(o.x), Double(o.y)], forKey: "panelOrigin")
        // 用户接管了位置：上移展开的「回位」记账作废
        liftedTopY = nil
        expandAnchorTopY = nil
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
        if editingId != nil { scrollEditorIntoViewIfNeeded() }
    }

    /// 高度封顶 + 滚动引入后的补充：点视口下部/上部的行时，编辑卡可能整个落在折叠区，
    /// 用户看起来像「点了没反应」。打开后把卡片平移进可视范围（内容够滚时）。
    /// AppKit y 向上：卡片超出视口下缘（maxY > viewport）要减小 offset（往上滚回）。
    private func scrollEditorIntoViewIfNeeded() {
        guard viewportH > 0, rowsContentH > viewportH, let editor = activeInlineView else { return }
        let card = rowsClip.convert(editor.frame, from: editor.superview ?? rowsContainer)
        let viewport = rowsClip.bounds.height
        let maxOffset = max(0, rowsContentH - viewportH)
        if card.maxY > viewport + 0.5 {
            scrollOffset = max(scrollOffset - (card.maxY - viewport), 0)
            layoutChrome()
        } else if card.minY < -0.5 {
            scrollOffset = min(scrollOffset - card.minY, maxOffset)
            layoutChrome()
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
        _ = Resident.toggle()   // 常驻真实状态只有 launchd 一份，菜单勾选在 menuNeedsUpdate 里重读
    }

    @objc private func openDataFolder() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        NSWorkspace.shared.open(base.appendingPathComponent("AI到期提醒", isDirectory: true))
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
        panel.makeKeyAndOrderFront(nil)
        Motion.reveal(panel)
    }

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
    /// TestRender 断言用：原尺寸胶囊的当前适配字号。
    var debugPillFontSize: CGFloat { pillLabel.font?.pointSize ?? 0 }
    var debugPillLabel: NSTextField { pillLabel }
    func debugShowInlineEditor() {
        if let first = Store.shared.manualItems.first(where: { !$0.isAuto }) {
            editingId = first.id
        }
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
