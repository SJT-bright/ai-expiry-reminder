import AppKit
import QuartzCore

// MARK: - 悬停浮起按钮
// 鼠标移入：缓慢垂直上浮 + 高亮（不缩放）；移出：落下还原。边框磨圆胶囊裁切。

class HoverEffectButton: NSButton {
    /// 兼容旧调用点；悬停不再放大（图层默认 anchorPoint=(0,0)，缩放会左右错位）
    var hoverScale: CGFloat = 1
    /// 悬停中标记
    private(set) var isHovered = false
    /// 静止时的胶囊底色。悬停高亮结束后必须回到这个颜色，不能清成透明。
    var restFill: NSColor? {
        didSet {
            wantsLayer = true
            if !isHovered { layer?.backgroundColor = restFill?.cgColor }
        }
    }
    /// 芯片按钮内边距：isBordered=false 的固有尺寸默认只有文字大小，加上它才有可点的面
    var contentPadding = NSEdgeInsets() {
        didSet { invalidateIntrinsicContentSize() }
    }
    private var tracking: NSTrackingArea?

    override var intrinsicContentSize: NSSize {
        let s = super.intrinsicContentSize
        let p = contentPadding
        guard p.top != 0 || p.left != 0 || p.bottom != 0 || p.right != 0 else { return s }
        return NSSize(width: s.width + p.left + p.right,
                      height: max(s.height + p.top + p.bottom, 20))
    }

    /// 胶囊裁切：圆角半径取短边一半，masksToBounds 把描边/高亮收进胶囊。
    /// 系统按钮格子会自己铺一层不透明底，暗色窗上会把白字盖没，这里清掉。
    override func layout() {
        super.layout()
        wantsLayer = true
        (cell as? NSButtonCell)?.backgroundColor = .clear
        layer?.cornerRadius = min(bounds.height, bounds.width) / 2
        layer?.masksToBounds = true
        if !isHovered { layer?.backgroundColor = restFill?.cgColor }
    }

    /// 点击音前置到按下瞬间；动作仍在 mouseUp 经 NSButton 标准跟踪触发（拖出取消语义不变）。
    /// 不再 bounce 缩放：同样会因 anchorPoint=(0,0) 横向错位。
    override func mouseDown(with event: NSEvent) {
        if isEnabled { Motion.playTap() }
        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let ta = NSTrackingArea(rect: bounds,
                                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        tracking = ta
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        isHovered = true
        Motion.float(self, on: true, lift: 3.5)
        Motion.highlight(self, on: true, color: NSColor(white: 1, alpha: 0.18),
                         rest: restFill ?? .clear)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        Motion.float(self, on: false)
        Motion.highlight(self, on: false, color: NSColor(white: 1, alpha: 0.18),
                         rest: restFill ?? .clear)
    }
}

// MARK: - 渐入动效（fade-in reveal）
// 规格：0.35s 入场，透明度 0.55→1，ease-out，无位移无缩放。
// 早先这里还挂一层 CIGaussianBlur 6px→0 的"虚化渐入"，那是磨砂时代的补票动作：
// 现在根容器是系统液态玻璃，再叠一层 Core Image 模糊等于每开一次就把玻璃糊成磨砂，
// 且滤镜挂在 contentView.layer 上会污染后续合成，故整条模糊链路删除，只留透明度。
// 遵循系统「减弱动态效果」；TestRender 置 enabled=false 保证截图与断言同步。

enum Motion {
    /// 全局开关：测试环境置 false（所有动效直通最终态）
    static var enabled = true
    /// 动效时长常量（集中调参）：A 档
    static let revealDuration: TimeInterval = 0.35
    static let startAlpha: CGFloat = 0.55

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    /// 统一判定：动效总开关 + 系统减弱动态效果。任何「先摆起始态再动画」的代码
    /// 都必须用它做前置判断，Motion 关闭时直接落最终态（测试截图依赖这一点）。
    static var canAnimate: Bool { enabled && !reduceMotion }
    /// 系统 Tink；找不到再读 /System/Library/Sounds/Tink.aiff。首次真正播放时才加载。
    private static let tapSound: NSSound? = NSSound(named: "Tink")
        ?? NSSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true)

    /// 渐入（窗口）：只走透明度，几何与滤镜都不碰
    static func reveal(_ window: NSWindow, duration: TimeInterval = revealDuration) {
        guard enabled, !reduceMotion else { return }
        window.alphaValue = startAlpha
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1.0
        })
    }

    /// 渐入（视图）：只走透明度
    static func reveal(_ view: NSView, duration: TimeInterval = revealDuration) {
        guard enabled, !reduceMotion else { return }
        view.alphaValue = startAlpha
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = 1.0
        })
    }

    /// 编辑卡在自己的最终位置向屏幕前浮出：轻微放大并淡入，没有垂直位移。
    /// 只动画新卡的呈现层；模型层保持最终状态，重复点击不会把整列重播。
    static func popForward(_ view: NSView) {
        popIn(view)
    }

    /// 通用「向前浮出」：scale 0.96→1 + 可选垂直位移（dy<0 = 从下方浮起）+ 可选淡入。
    /// 位移走呈现层、模型层直接落最终态，重复触发不会从原点重播。
    /// 缩放必须补偿 anchorPoint=(0,0)：托管图层以左下为锚，直接缩放会横向错位。
    static func popIn(_ view: NSView, duration: TimeInterval = 0.22,
                      startScale: CGFloat = 0.96, dy: CGFloat = 0,
                      startAlpha: CGFloat? = 0.65) {
        guard canAnimate else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let timing = CAMediaTimingFunction(name: .easeOut)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = startScale
        scale.toValue = 1.0
        scale.duration = duration
        scale.timingFunction = timing
        let x = CABasicAnimation(keyPath: "transform.translation.x")
        x.fromValue = layer.bounds.width * (1 - startScale) / 2
        x.toValue = 0
        x.duration = duration
        x.timingFunction = timing
        let y = CABasicAnimation(keyPath: "transform.translation.y")
        y.fromValue = layer.bounds.height * (1 - startScale) / 2 + dy
        y.toValue = 0
        y.duration = duration
        y.timingFunction = timing
        layer.add(scale, forKey: "popForward.scale")
        layer.add(x, forKey: "popForward.x")
        layer.add(y, forKey: "popForward.y")
        if let startAlpha {
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = startAlpha
            opacity.toValue = 1.0
            opacity.duration = duration
            opacity.timingFunction = timing
            layer.add(opacity, forKey: "popForward.opacity")
        }
    }

    /// 页面级滑入（月历翻页、控制区展开）：从 (dx, dy) 偏移滑到原位并淡入。
    /// 位移走呈现层；透明度走 AppKit alphaValue 体系（与视图 alpha 不打架）。
    static func slideIn(_ view: NSView, dx: CGFloat = 0, dy: CGFloat = 0,
                        duration: TimeInterval = 0.26, startAlpha: CGFloat = 0.25) {
        guard canAnimate else { return }
        view.wantsLayer = true
        if let layer = view.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = CATransform3DIdentity
            CATransaction.commit()
            let timing = CAMediaTimingFunction(name: .easeInEaseOut)
            func add(_ keyPath: String, _ from: CGFloat, _ key: String) {
                let a = CABasicAnimation(keyPath: keyPath)
                a.fromValue = from
                a.toValue = 0
                a.duration = duration
                a.timingFunction = timing
                layer.add(a, forKey: key)
            }
            if dx != 0 { add("transform.translation.x", dx, "motionSlideIn.x") }
            if dy != 0 { add("transform.translation.y", dy, "motionSlideIn.y") }
        }
        view.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = 1
        }
    }

    /// 页面级滑出（旧页退场）：滑向 (dx, dy) 并淡出；completion 后由调用方移除视图。
    /// Motion 关闭时同步回调 completion，调用方据此立即拆除，行为与无动画一致。
    static func slideOut(_ view: NSView, dx: CGFloat = 0, dy: CGFloat = 0,
                         duration: TimeInterval = 0.26, completion: (() -> Void)? = nil) {
        guard canAnimate else { completion?(); return }
        view.wantsLayer = true
        if let layer = view.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = CATransform3DTranslate(CATransform3DIdentity, dx, dy, 0)
            CATransaction.commit()
            let timing = CAMediaTimingFunction(name: .easeInEaseOut)
            func add(_ keyPath: String, _ to: CGFloat, _ key: String) {
                let a = CABasicAnimation(keyPath: keyPath)
                a.fromValue = 0
                a.toValue = to
                a.duration = duration
                a.timingFunction = timing
                layer.add(a, forKey: key)
            }
            if dx != 0 { add("transform.translation.x", dx, "motionSlideOut.x") }
            if dy != 0 { add("transform.translation.y", dy, "motionSlideOut.y") }
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            view.animator().alphaValue = 0
        }, completionHandler: completion)
    }

    /// 淡出：动画到全透明后回调，隐藏与恢复 alpha 由调用方决定（调用方可能要按
    /// 当前状态决定是否真的藏——快速往返时 completion 可能已经过期）。
    /// Motion 关闭时同步回调，最终态（全透明）由调用方落地。
    static func fadeOut(_ view: NSView, duration: TimeInterval = 0.15,
                        completion: (() -> Void)? = nil) {
        guard canAnimate else { completion?(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            view.animator().alphaValue = 0
        }, completionHandler: completion)
    }

    /// 轻量淡入（无模糊，适合行级小元素）；delay>0 时先隐藏再延迟入场
    static func fadeIn(_ view: NSView, duration: TimeInterval = revealDuration, delay: TimeInterval = 0) {
        guard enabled, !reduceMotion else { return }
        if delay > 0 {
            view.alphaValue = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
                guard let view, view.window != nil else { return }
                fadeIn(view, duration: duration)
            }
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            view.alphaValue = 1
        })
    }

    /// 文本变化交叉淡入（药丸倒计时等高频小变化）
    static func crossfadeText(_ label: NSTextField, update: @escaping () -> Void) {
        guard enabled, !reduceMotion else { update(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            label.animator().alphaValue = 0.25
        }, completionHandler: {
            update()
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                label.animator().alphaValue = 1
            })
        })
    }

    /// 按压反馈：只做 0.12s 透明度 0.75↔1。不再 float 缩放，避免行点击横向错位。
    static func press(_ view: NSView, pressed: Bool) {
        guard enabled, !reduceMotion else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            view.animator().alphaValue = pressed ? 0.75 : 1
        }
    }

    /// 点击反馈：不再改 transform（缩放同样会横向错位）。极短透明度闪一下。`to` 保留兼容，忽略。
    static func bounce(_ view: NSView, to scale: CGFloat = 1) {
        _ = scale
        guard enabled, !reduceMotion else { return }
        let restored = view.alphaValue
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.06
            view.animator().alphaValue = 0.78
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.08
                view.animator().alphaValue = restored
            }
        })
    }

    /// 点击轻提示音。系统 Tink；找不到再读系统路径。static 缓存，只在主线程播放。
    /// 测试里 Motion.enabled=false，guard 直接返回，不会出声、也不会加载声音。
    static func playTap() {
        guard enabled, !reduceMotion else { return }
        if !Thread.isMainThread {
            DispatchQueue.main.async { playTap() }
            return
        }
        tapSound?.play()
    }

    /// 悬停浮起：只动画 transform.translation.y，缓慢垂直上浮、无过冲。
    /// `scale` 保留签名但忽略——缩放会让 NSView 图层横向错位（托管图层默认 anchorPoint=(0,0)，
    /// 以左下为锚放大，视觉上像位置跳了）。禁止 CASpringAnimation / setAffineTransform 混缩放。
    static func float(_ view: NSView, on: Bool, scale: CGFloat = 1.02, lift: CGFloat = 3,
                      animated: Bool = true) {
        _ = scale
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        // 先取呈现位置再撤旧动画，快速往返时从正在显示的位置继续，不跳回模型终点。
        let fromY = (layer.presentation() ?? layer)
            .value(forKeyPath: "transform.translation.y") as? CGFloat ?? 0
        layer.removeAnimation(forKey: "motionBounce.scale")
        layer.removeAnimation(forKey: "motionFloat.transform.scale")
        layer.removeAnimation(forKey: "motionFloat.transform.translation.y")
        layer.removeAnimation(forKey: "motionFloat.y")

        let dy: CGFloat = enabled && !reduceMotion && on ? lift : 0
        if enabled && !reduceMotion && animated {
            let anim = CABasicAnimation(keyPath: "transform.translation.y")
            anim.fromValue = fromY
            anim.toValue = dy
            anim.duration = on ? 0.28 : 0.34
            anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.61, 0.36, 1)
            layer.add(anim, forKey: "motionFloat.y")
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DTranslate(CATransform3DIdentity, 0, dy, 0)
        CATransaction.commit()
    }

    /// 悬停高亮（持续态）：背景层明暗柔和渐变
    static func highlight(_ view: NSView, on: Bool, color: NSColor = NSColor(white: 1, alpha: 0.05),
                          rest: NSColor = .clear, animated: Bool = true) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let from = (layer.presentation() ?? layer).backgroundColor
        let target = (on ? color : rest).cgColor
        layer.removeAnimation(forKey: "motionHighlight.color")
        if enabled && !reduceMotion && animated {
            let anim = CABasicAnimation(keyPath: "backgroundColor")
            anim.fromValue = from
            anim.toValue = target
            anim.duration = on ? 0.22 : 0.28
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(anim, forKey: "motionHighlight.color")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = target
        CATransaction.commit()
    }

    // MARK: - 窗口级过渡

    /// 窗口出场：整体淡入 + 内容从 97% 轻微上浮 pop 出来（透明度只走窗口层，内容只做几何）。
    /// 用于独立二级窗（设置后台、提前提醒）；悬浮窗的出场仍用 reveal（几何由窗口尺寸动画负责）。
    static func present(_ window: NSWindow, duration: TimeInterval = 0.26) {
        guard canAnimate else { return }
        reveal(window, duration: duration)
        if let content = window.contentView {
            popIn(content, duration: duration, startScale: 0.97, dy: -5, startAlpha: nil)
        }
    }

    /// 窗口退场：淡出后 orderOut，并恢复 alpha 供下次显示。Motion 关闭时同步 orderOut。
    static func dismissWindow(_ window: NSWindow, duration: TimeInterval = 0.16,
                              completion: (() -> Void)? = nil) {
        guard canAnimate, window.isVisible else {
            window.orderOut(nil)
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.orderOut(nil)
            window.alphaValue = 1
            completion?()
        })
    }

    /// 窗口 frame 过渡（胶囊↔面板、归位滑动）：frame 变化走 animator，内容随每一步
    /// 真实 resize 重排。frame 未变或动效关闭时同步落位并回调。
    static func animateWindowFrame(_ window: NSWindow, to frame: NSRect,
                                   duration: TimeInterval = 0.3,
                                   completion: (() -> Void)? = nil) {
        guard canAnimate, !NSEqualRects(frame, window.frame) else {
            window.setFrame(frame, display: true)
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }, completionHandler: completion)
    }
}
