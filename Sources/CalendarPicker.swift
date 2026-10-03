import AppKit

// MARK: - 月历浮层（DateTextField 的日期选择弹层）
//
// 底板走工程统一的 Glass（与悬浮窗同一口径），减弱动效判断仍就地取——不为两行代码把 Motion 拖进来。

/// 日历浮层窗口。
/// canBecomeKey / canBecomeMain 恒为 false 是整块设计的支点：
/// 宿主要么是 .nonactivatingPanel 悬浮窗，要么是带「保存/取消」的 sheet——
/// 那两个按钮占着 Return / Escape 的 keyEquivalent。日历一抢 key 窗口，
/// 回车就不再触发保存。所以日历全程只吃鼠标，键盘一律不接管。
final class CalendarPickerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 自上而下排版：行列号即视觉位置，省掉一堆 y = height - … 的翻转换算
private final class CalendarFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 深色玻璃上的扁方块：自绘圆角底 + 居中字。
/// 不用 NSButton 默认样式：透明无边框面板里系统按钮会发灰、带焦点环，暗底对比度不可控。
private final class CalendarTileButton: NSButton {
    var corner: CGFloat = 7 { didSet { layer?.cornerRadius = corner } }
    /// 强调色实心（选中日 / 当前月 / 「确定」）
    var filled = false
    /// 今日描边：与「选中的实心」是两套独立处理，可叠加在同一格
    var todayMark = false
    /// 非本月的补位日：淡显；配合 isEnabled = false 使其点不动
    var dimmed = false
    var text = ""
    var textFont: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    var textColorOverride: NSColor?
    /// 格子所属日期（供点击与自动化定位；0 表示无意义）
    var yearValue = 0
    var monthValue = 0
    var dayValue = 0

    private var hovering = false
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        title = ""
        wantsLayer = true
        layer?.cornerRadius = corner
        setButtonType(.momentaryChange)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if tracking == nil {
            let ta = NSTrackingArea(rect: bounds,
                                    options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                    owner: self, userInfo: nil)
            addTrackingArea(ta)
            tracking = ta
        }
    }

    // 浮层不是 key 窗口，悬停态只能自标（.activeAlways 保证应用未激活时也收到 enter/exit）
    override func mouseEntered(with event: NSEvent) {
        guard isEnabled, !dimmed, !filled, !hovering else { return }
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hovering else { return }
        hovering = false
        needsDisplay = true
    }

    /// 不调 super.draw：外观完全自绘，按下态用 isHighlighted 手动表达
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: corner, yRadius: corner)
        if filled {
            NSColor.controlAccentColor.setFill()
            path.fill()
        } else if isHighlighted {
            NSColor(white: 1, alpha: 0.22).setFill()
            path.fill()
        } else if hovering {
            NSColor(white: 1, alpha: 0.10).setFill()
            path.fill()
        }
        if todayMark {
            // 未选中时环用强调色；已被强调色填满时改白环，否则同色融掉看不见
            let inset = bounds.insetBy(dx: 1.4, dy: 1.4)
            let ring = NSBezierPath(roundedRect: inset, xRadius: max(2, corner - 1), yRadius: max(2, corner - 1))
            (filled ? NSColor(white: 1, alpha: 0.9) : NSColor.controlAccentColor).setStroke()
            ring.lineWidth = 1
            ring.stroke()
        }
        guard !text.isEmpty else { return }
        let color = textColorOverride ?? (filled ? NSColor.white
                                    : dimmed ? NSColor(white: 1, alpha: 0.24)
                                    : NSColor(white: 1, alpha: 0.88))
        let attrs: [NSAttributedString.Key: Any] = [.font: textFont, .foregroundColor: color]
        let s = text as NSString
        let sz = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2), withAttributes: attrs)
    }
}

private enum CalendarMetrics {
    static let width: CGFloat = 240
    static let padX: CGFloat = 10
    static let padTop: CGFloat = 9
    static let padBottom: CGFloat = 9
    static let headerH: CGFloat = 22
    static let weekdayH: CGFloat = 14
    static let cellW: CGFloat = 28
    static let cellH: CGFloat = 24
    static let gapX: CGFloat = 4
    static let rowH: CGFloat = 26
    static let rows = 6
    static let gridGap: CGFloat = 3
    static let footerGap: CGFloat = 9
    static let footerH: CGFloat = 24
    static let corner: CGFloat = 10

    static let gridW = cellW * 7 + gapX * 6           // 220 = width - 2*padX
    static let gridH = rowH * CGFloat(rows)           // 156
    static var height: CGFloat {
        padTop + headerH + gridGap + weekdayH + gridGap + gridH + footerGap + footerH + padBottom
    }
}

// MARK: - 控制器

/// 月历浮层唯一入口。全局单例 + 单窗口：同一时刻最多一层日历。
final class CalendarPickerController: NSObject {
    static let shared = CalendarPickerController()

    /// 打开中：宿主据此抑制悬浮窗自动收起等副作用
    private(set) var isVisible = false
    var onOpenChanged: ((Bool) -> Void)?

    // MARK: 会话状态

    private var panel: CalendarPickerPanel?
    /// weak：宿主窗口的生命周期不由日历决定，浮层不该把它留住
    private weak var host: NSWindow?
    private var anchorRect = NSRect.zero
    private var initial = Date()
    private var onPick: ((Date) -> Void)?
    private var selected = Date()
    /// 当前显示的月份（恒为该月 1 号）
    private var displayed = Date()
    private enum Mode { case grid, months }
    private var mode: Mode = .grid

    private var container: CalendarFlippedView?
    private var dayCells: [CalendarTileButton] = []

    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    /// 跨 App 离开的主信号（NSWorkspace 激活切换）；无授权门槛
    private var activeAppObserver: NSObjectProtocol?
    /// 补充信号：global 鼠标监视，要「辅助功能」授权，没授权时永不回调 —— 绝不能当唯一出口
    private var globalMouseMonitor: Any?
    private var hostObservers: [NSObjectProtocol] = []

    private let cal = Calendar.current

    private override init() { super.init() }

    // MARK: 对外

    /// 在 hostWindow 内、anchorRect 下方弹出日历。已打开时不叠第二层：换参数后重定位刷新。
    /// anchorRect 约定为 hostWindow 的视图坐标系（未翻转）；若取自 flipped 视图，
    /// 调用方先 view.convert(_, to: nil) 再传进来。
    func present(initial: Date, anchorRect: NSRect, in hostWindow: NSWindow, onPick: @escaping (Date) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.present(initial: initial, anchorRect: anchorRect, in: hostWindow, onPick: onPick)
            }
            return
        }
        self.initial = initial
        self.selected = initial
        self.displayed = startOfMonth(initial)
        self.anchorRect = anchorRect
        self.host = hostWindow
        self.onPick = onPick
        self.mode = .grid

        if let panel {                       // 复用：监视器已装好，只需改盯新宿主
            observeHost()
            rebuild()
            position(panel)
            return
        }
        buildPanel()
        guard let panel else { return }
        rebuild()
        position(panel)
        installMonitors()
        observeHost()
        panel.orderFrontRegardless()         // 应用可能未激活，orderFront 不足以显示
        fadeIn(panel)
        isVisible = true
        onOpenChanged?(true)
    }

    /// 幂等：已关闭时调用无副作用；关闭一律摘净监视器与观察者（全程无计时器，故无残留）
    func dismiss() {
        let wasVisible = isVisible
        guard wasVisible || panel != nil else { return }
        isVisible = false                    // 先置位：监视器回调里重入 dismiss 时直接 bail
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
        if let o = activeAppObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        activeAppObserver = nil
        for o in hostObservers { NotificationCenter.default.removeObserver(o) }
        hostObservers.removeAll()
        panel?.orderOut(nil)
        panel = nil
        container = nil
        dayCells.removeAll()
        onPick = nil
        host = nil
        if wasVisible { onOpenChanged?(false) }
    }

    // MARK: 自动化钩子（仅测试用，生产路径不碰）

    /// 当前浮层窗口；关闭时为 nil。用于断言「同一时刻只有一个日历窗口」
    var debugPanel: NSWindow? { panel }

    /// 监视器 / 观察者是否已彻底摘除（dismiss 后必须为 true）
    var debugTeardownClean: Bool {
        mouseMonitor == nil && keyMonitor == nil && globalMouseMonitor == nil
            && activeAppObserver == nil && hostObservers.isEmpty
    }

    /// 本月可点格数（自动化用：等于该月天数）
    var debugEnabledDayCellCount: Int { dayCells.filter { $0.isEnabled }.count }

    /// 导航到 (y, m) 后点击该日格子，与真实点击走同一条 action 链路。
    /// 返回 false = 该日不在本月可点格子里。
    @discardableResult
    func debugTap(year: Int, month: Int, day: Int) -> Bool {
        guard isVisible,
              let target = date(year: year, month: month, day: day, keepingTimeOf: initial) else { return false }
        let monthStart = startOfMonth(target)
        if mode != .grid { mode = .grid }
        if monthStart != displayed { displayed = monthStart }
        rebuild()
        guard let cell = dayCells.first(where: {
            $0.yearValue == year && $0.monthValue == month && $0.dayValue == day && $0.isEnabled
        }) else { return false }
        cell.performClick(nil)               // 真走按钮链路，而不是绕过 UI 直接 commit
        return true
    }

    // MARK: 建窗与定位

    private func buildPanel() {
        let size = NSSize(width: CalendarMetrics.width, height: CalendarMetrics.height)
        let p = CalendarPickerPanel(contentRect: NSRect(origin: .zero, size: size),
                                    styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        // .popUpMenu 同时压过 .floating 悬浮窗与普通窗口：两种宿主都在它下面
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true              // 玻璃只管「透出背后」，浮层与宿主的分离感还得靠窗影
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.appearance = NSAppearance(named: .darkAqua)
        p.isMovableByWindowBackground = false
        p.worksWhenModal = true              // 期间弹 NSAlert（删除确认）也不该把浮层卡成死板
        p.isExcludedFromWindowsMenu = true

        // 玻璃自己就是材质：手描的 1px 亮边和暗垫会把折射压平（实测），一律不画。
        // 圆角必须由玻璃给（10 沿用旧轮廓）——无边框窗不裁圆角，给 0 就是张方纸。
        let glass = Glass.make(cornerRadius: CalendarMetrics.corner, tint: Glass.bodyTint)
        glass.autoresizingMask = [.width, .height]

        let box = CalendarFlippedView(frame: NSRect(origin: .zero, size: size))
        box.autoresizingMask = [.width, .height]
        // 内容只能走 contentView：头文件明说兄弟子视图与玻璃的 z-order 系统不保证
        glass.contentView = box
        p.contentView = glass                // 漏了这行就是「玻璃板有了、内容全在天上」
        panel = p
        container = box
    }

    /// 屏幕坐标 y 轴向上，「下方」即减小 y。
    /// 右侧放不下 → 改成沿 anchor 右端对齐向左展开；下方空间不足 → 翻到上方；最后夹进宿主所在屏。
    private func position(_ p: NSWindow) {
        guard let host else { return }
        let scr = host.screen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(host.frame) })
            ?? NSScreen.main
        guard let scr else { return }
        let size = p.frame.size
        let gap: CGFloat = 4
        let a = host.convertToScreen(anchorRect)
        var x = a.minX
        if x + size.width > scr.frame.maxX - 4 { x = a.maxX - size.width }
        var y = a.minY - gap - size.height
        if y < scr.frame.minY + 4 { y = a.maxY + gap }
        let minX = scr.frame.minX + 4, maxX = max(minX, scr.frame.maxX - size.width - 4)
        let minY = scr.frame.minY + 4, maxY = max(minY, scr.frame.maxY - size.height - 4)
        p.setFrame(NSRect(x: min(max(x, minX), maxX), y: min(max(y, minY), maxY),
                          width: size.width, height: size.height), display: true)
    }

    /// 与 Motion.reveal 同族但更短：弹层不该有存在感，淡入即可；遵循系统「减弱动态效果」
    private func fadeIn(_ p: NSWindow) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        p.alphaValue = 0.7
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }
    }

    // MARK: 内容构建

    private func rebuild() {
        guard let box = container else { return }
        box.subviews.forEach { $0.removeFromSuperview() }
        dayCells.removeAll()

        let weekdayY = CalendarMetrics.padTop + CalendarMetrics.headerH + CalendarMetrics.gridGap
        let gridY = weekdayY + CalendarMetrics.weekdayH + CalendarMetrics.gridGap

        buildHeader(in: box, y: CalendarMetrics.padTop)
        buildWeekdays(in: box, y: weekdayY)
        switch mode {
        case .grid: buildDayGrid(in: box, y: gridY)
        case .months: buildMonthGrid(in: box, y: gridY)
        }
        buildFooter(in: box, y: gridY + CalendarMetrics.gridH + CalendarMetrics.footerGap)
    }

    private func buildHeader(in box: NSView, y: CGFloat) {
        let h = CalendarMetrics.headerH
        // 标题就是年/月跳转入口：点一下进 12 月列表，此时 ‹ › 变成翻年（比长按可靠）
        let title = makeButton(frame: NSRect(x: 0, y: y, width: CalendarMetrics.width, height: h),
                               text: mode == .grid ? "\(year(of: displayed))年\(month(of: displayed))月"
                                                   : "\(year(of: displayed))年 · 选月份",
                               action: #selector(toggleMode),
                               font: .systemFont(ofSize: 12, weight: .semibold))
        title.textColorOverride = NSColor(white: 1, alpha: 0.95)
        title.setAccessibilityIdentifier("calTitle")
        let prev = makeButton(frame: NSRect(x: CalendarMetrics.padX, y: y, width: 26, height: h),
                              text: "‹", action: #selector(stepBackward),
                              font: .systemFont(ofSize: 15, weight: .medium))
        prev.setAccessibilityIdentifier("calPrev")
        let next = makeButton(frame: NSRect(x: CalendarMetrics.width - CalendarMetrics.padX - 26, y: y,
                                            width: 26, height: h),
                              text: "›", action: #selector(stepForward),
                              font: .systemFont(ofSize: 15, weight: .medium))
        next.setAccessibilityIdentifier("calNext")
        box.addSubview(title)
        box.addSubview(prev)
        box.addSubview(next)
    }

    private func buildWeekdays(in box: NSView, y: CGFloat) {
        // 恒周一起：工程里「1=周一…7=周日」是既有语义，不跟随 locale 的 firstWeekday
        for (i, name) in ["一", "二", "三", "四", "五", "六", "日"].enumerated() {
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 9)
            label.textColor = NSColor(white: 1, alpha: i >= 5 ? 0.45 : 0.62)
            label.alignment = .center
            label.frame = NSRect(x: CalendarMetrics.padX + CGFloat(i) * (CalendarMetrics.cellW + CalendarMetrics.gapX),
                                 y: y, width: CalendarMetrics.cellW, height: CalendarMetrics.weekdayH)
            box.addSubview(label)
        }
    }

    private func buildDayGrid(in box: NSView, y: CGFloat) {
        // 恒 6 行（42 格）：切月时高度不跳，浮层与 anchor 的相对位置也就稳定
        let leading = (cal.component(.weekday, from: displayed) + 5) % 7   // 1=周日 → 周一列偏移 0…周日 6
        for i in 0..<(CalendarMetrics.rows * 7) {
            guard let d = cal.date(byAdding: .day, value: i - leading, to: displayed) else { continue }
            let x = CalendarMetrics.padX + CGFloat(i % 7) * (CalendarMetrics.cellW + CalendarMetrics.gapX)
            let cy = y + CGFloat(i / 7) * CalendarMetrics.rowH
                + (CalendarMetrics.rowH - CalendarMetrics.cellH) / 2
            let cell = CalendarTileButton(frame: NSRect(x: x, y: cy, width: CalendarMetrics.cellW,
                                                        height: CalendarMetrics.cellH))
            cell.text = "\(day(of: d))"
            cell.yearValue = year(of: d)
            cell.monthValue = month(of: d)
            cell.dayValue = day(of: d)
            let inMonth = cell.yearValue == year(of: displayed) && cell.monthValue == month(of: displayed)
            cell.dimmed = !inMonth
            cell.isEnabled = inMonth          // 补位日淡显且不可点：不跨月跳，也不留「点了没反应」的坑
            cell.target = self
            cell.action = #selector(pickDay(_:))
            cell.setAccessibilityIdentifier("calDay-\(cell.yearValue)-\(cell.monthValue)-\(cell.dayValue)")
            mark(cell)
            box.addSubview(cell)
            dayCells.append(cell)
        }
    }

    private func buildMonthGrid(in box: NSView, y: CGFloat) {
        let cols = 4, cw: CGFloat = 50, ch: CGFloat = 44, rowGap: CGFloat = 12
        let gap = (CalendarMetrics.gridW - cw * CGFloat(cols)) / CGFloat(cols - 1)
        let top = y + (CalendarMetrics.gridH - (ch * 3 + rowGap * 2)) / 2
        for m in 1...12 {
            let b = CalendarTileButton(frame: NSRect(
                x: CalendarMetrics.padX + CGFloat((m - 1) % cols) * (cw + gap),
                y: top + CGFloat((m - 1) / cols) * (ch + rowGap),
                width: cw, height: ch))
            b.text = "\(m)月"
            b.corner = 8
            b.yearValue = year(of: displayed)
            b.monthValue = m
            b.filled = m == month(of: selected) && year(of: displayed) == year(of: selected)
            b.target = self
            b.action = #selector(pickMonth(_:))
            b.setAccessibilityIdentifier("calMonth-\(m)")
            box.addSubview(b)
        }
    }

    private func buildFooter(in box: NSView, y: CGFloat) {
        let today = makeButton(frame: NSRect(x: CalendarMetrics.padX, y: y, width: 62, height: CalendarMetrics.footerH),
                               text: "今天", action: #selector(pickToday), font: .systemFont(ofSize: 11))
        today.setAccessibilityIdentifier("calToday")
        // 「确定」提交当前选中日（从没选过就是 initial 那天）：值恒等，所以幂等；
        // 做成「关闭」反而多一条「用户以为已经保存了」的歧义分支
        let confirm = makeButton(frame: NSRect(x: CalendarMetrics.width - CalendarMetrics.padX - 56, y: y,
                                               width: 56, height: CalendarMetrics.footerH),
                                 text: "确定", action: #selector(confirmPick),
                                 font: .systemFont(ofSize: 11, weight: .semibold))
        confirm.filled = true
        confirm.corner = 6
        confirm.setAccessibilityIdentifier("calConfirm")
        box.addSubview(today)
        box.addSubview(confirm)
    }

    private func makeButton(frame: NSRect, text: String, action: Selector, font: NSFont) -> CalendarTileButton {
        let b = CalendarTileButton(frame: frame)
        b.text = text
        b.textFont = font
        b.corner = 6
        b.target = self
        b.action = action
        return b
    }

    /// 今日 = 描边、选中 = 实心：两套标记互不覆盖，同格可并存
    private func mark(_ cell: CalendarTileButton) {
        let t = Date()
        cell.todayMark = cell.yearValue == year(of: t) && cell.monthValue == month(of: t) && cell.dayValue == day(of: t)
        cell.filled = cell.yearValue == year(of: selected) && cell.monthValue == month(of: selected)
            && cell.dayValue == day(of: selected)
    }

    // MARK: 动作

    @objc private func stepBackward() { shift(-1) }
    @objc private func stepForward() { shift(1) }

    private func shift(_ delta: Int) {
        let unit: Calendar.Component = mode == .grid ? .month : .year
        displayed = cal.date(byAdding: unit, value: delta, to: displayed) ?? displayed
        rebuild()
    }

    @objc private func toggleMode() {
        mode = mode == .grid ? .months : .grid
        rebuild()
    }

    @objc private func pickMonth(_ sender: CalendarTileButton) {
        displayed = date(year: sender.yearValue, month: sender.monthValue, day: 1, keepingTimeOf: displayed)
            ?? displayed
        mode = .grid
        rebuild()
    }

    @objc private func pickDay(_ sender: CalendarTileButton) {
        guard sender.isEnabled,
              let d = date(year: sender.yearValue, month: sender.monthValue, day: sender.dayValue,
                           keepingTimeOf: initial) else { return }
        selected = d
        commit(d)
    }

    /// 「今天」直接提交今天（哪怕正看着别的月份）：与系统选择器语义一致，不做静默翻页
    @objc private func pickToday() {
        let t = Date()
        guard let d = date(year: year(of: t), month: month(of: t), day: day(of: t), keepingTimeOf: initial) else { return }
        selected = d
        commit(d)
    }

    @objc private func confirmPick() { commit(selected) }

    /// 先收窗再回调：onPick 里往往要重排宿主甚至弹 alert，别让浮层还挂在屏幕上
    private func commit(_ d: Date) {
        let cb = onPick
        dismiss()
        cb?(d)
    }

    // MARK: 日期换算（时:分:秒一律沿用 initial，绝不落 0）

    private func date(year: Int, month: Int, day: Int, keepingTimeOf ref: Date) -> Date? {
        var c = cal.dateComponents([.hour, .minute, .second, .nanosecond], from: ref)
        c.year = year
        c.month = month
        c.day = day
        guard let d = cal.date(from: c) else { return nil }
        let back = cal.dateComponents([.year, .month, .day], from: d)
        // 防 2/30 这类越界日静默进位：组回读必须与输入逐项一致
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return d
    }

    private func startOfMonth(_ d: Date) -> Date {
        cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
    }

    private func year(of d: Date) -> Int { cal.component(.year, from: d) }
    private func month(of d: Date) -> Int { cal.component(.month, from: d) }
    private func day(of d: Date) -> Int { cal.component(.day, from: d) }

    // MARK: 收起链路

    /// 三条出口各司其职，且必须叠着来：
    /// local 监视只看得到投给本 App 的事件；global 监视要授权；激活通知补上「点了别的 App」这一大块。
    private func installMonitors() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isVisible, let p = self.panel else { return event }
            if event.window === p { return event }
            // locationInWindow 属于「事件所在窗口」的坐标，必须换到屏幕坐标再和自己的 frame 比
            let pt = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
            if p.frame.contains(pt) { return event }
            self.dismiss()
            return event                      // 原样放行：点宿主控件的那一下不该被吞掉
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            guard event.keyCode == 53 else { return event }
            self.dismiss()
            // 返回 nil：日历开着时 Escape 只关日历，不能顺带把 sheet 的「取消」也触发了
            return nil
        }
        // 主出口：跨 App 的「用户走人了」。宿主是 .nonactivatingPanel，应用常年不在前台，
        // 用户切到别的 App 时上面两个 local 监视一个事件都收不到，浮层就孤儿地挂在别人窗口上。
        // 必须挂到 NSWorkspace 自己的通知中心——挂 default 的那颗永远不响。无需任何授权。
        activeAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.isVisible else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            // 认 pid 不认 bundleIdentifier：accessory 应用与裸 swiftc 产物里它未必有值；
            // 激活的是我们自己就不算离开。取不到 app 一律按离开办——宁早关，不留孤儿浮层。
            if let app, app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
            self.dismiss()
        }
        // 补充出口，不是主路径：global 监视要「辅助功能」授权，未授权时静默失效（对象照样返回，
        // 只是永不回调），所以它挂了/没挂都不能影响上面两条。回调里 event.window 恒为 nil，
        // 只能拿鼠标屏幕坐标比 frame——浮层内部那一下绝不该被当成「去了别处」。
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.isVisible, let p = self.panel else { return }
            if p.frame.contains(NSEvent.mouseLocation) { return }
            self.dismiss()
        }
    }

    /// 宿主一动 / 一改尺寸 / 一关，浮层立刻收起（浮层锚在控件上，重算位置不如直接关清爽）。
    /// sheet 的父窗移动时 AppKit 不一定给子窗发 didMove，所以父窗一并监听。
    private func observeHost() {
        for o in hostObservers { NotificationCenter.default.removeObserver(o) }
        hostObservers.removeAll()
        guard let host else { return }
        var sources: [NSWindow] = [host]
        if let parent = host.parent, !sources.contains(where: { $0 === parent }) { sources.append(parent) }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification] {
            for w in sources {
                hostObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: w, queue: .main) { [weak self] _ in self?.dismiss() })
            }
        }
        // 依旧不用 didResignKey 当「用户走了」：从不 key 的窗口根本不发这条通知
        // （.nonactivatingPanel 宿主未激活时就是从不 key），要防的场景它一次都不响；
        // 等宿主真成了 key，自家弹 NSAlert / 起二级窗也会让它 resign，反倒误杀浮层。
        // 跨 App 那一路已由 installMonitors 里的激活通知接管，这里不留缺口。
    }
}
