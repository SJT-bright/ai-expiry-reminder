import AppKit
import QuartzCore

// MARK: - 悬停浮起按钮
// 鼠标移入：轻微放大浮起 + 高亮；移出：落下还原。全局统一交互语言。

class HoverEffectButton: NSButton {
    /// 悬停放大档：1.12 + 更亮的高亮层——「触感更强」的手感基准，全局按钮统一
    var hoverScale: CGFloat = 1.12
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

    override func mouseEntered(with event: NSEvent) {
        Motion.float(self, on: true, scale: hoverScale, lift: 1.0)
        Motion.highlight(self, on: true, color: NSColor(white: 1, alpha: 0.14))
    }

    override func mouseExited(with event: NSEvent) {
        Motion.float(self, on: false)
        Motion.highlight(self, on: false)
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
        guard enabled, !reduceMotion else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let duration: TimeInterval = 0.22
        let startScale: CGFloat = 0.96
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
        y.fromValue = layer.bounds.height * (1 - startScale) / 2
        y.toValue = 0
        y.duration = duration
        y.timingFunction = timing
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.65
        opacity.toValue = 1.0
        opacity.duration = duration
        opacity.timingFunction = timing
        layer.add(scale, forKey: "popForward.scale")
        layer.add(x, forKey: "popForward.x")
        layer.add(y, forKey: "popForward.y")
        layer.add(opacity, forKey: "popForward.opacity")
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

    /// 按压反馈：轻微降透明度
    static func press(_ view: NSView, pressed: Bool) {
        guard enabled, !reduceMotion else { return }
        view.alphaValue = pressed ? 0.7 : 1
    }

    /// 悬停浮起（柔和波浪）：阻尼弹簧过渡——轻柔上浮、一丝波浪回落再静止；离开时柔和落下。
    /// 以视图中心为锚轻微放大 + 垂直上浮；NSView 托管图层默认 anchorPoint=(0,0)，需平移补偿防斜漂。
    static func float(_ view: NSView, on: Bool, scale: CGFloat = 1.02, lift: CGFloat = 1.5) {
        guard enabled, !reduceMotion else { return }
        view.wantsLayer = true
        guard let layer = view.layer, layer.bounds.width > 0, layer.bounds.height > 0 else { return }
        let cx = layer.bounds.width / 2
        let cy = layer.bounds.height / 2
        let s: CGFloat = on ? scale : 1
        let dy: CGFloat = on ? lift : 0            // 非翻转视图图层 y 轴向上 → +y 即垂直上浮
        var t = CGAffineTransform(translationX: cx, y: cy)
        t = t.scaledBy(x: s, y: s)
        t = t.translatedBy(x: -cx, y: -cy)
        t = t.translatedBy(x: 0, y: dy)

        let current = (layer.presentation() ?? layer)
        layer.setAffineTransform(t)

        // 柔和波浪：低刚度 + 高阻尼的弹簧，过冲极小、缓缓落定
        // （用 translation.y / scale 两个数值通道，避免 macOS NSValue 对 transform 的包装差异）
        let fromY = current.value(forKeyPath: "transform.translation.y") as? CGFloat ?? 0
        let fromS = current.value(forKeyPath: "transform.scale") as? CGFloat ?? 1
        func addSpring(_ keyPath: String, from: CGFloat, to: CGFloat) {
            let spring = CASpringAnimation(keyPath: keyPath)
            spring.fromValue = from
            spring.toValue = to
            spring.mass = 1.1
            spring.stiffness = 110
            spring.damping = 16
            spring.duration = spring.settlingDuration
            spring.fillMode = .forwards
            spring.isRemovedOnCompletion = false
            layer.add(spring, forKey: "motionFloat." + keyPath)
        }
        addSpring("transform.translation.y", from: fromY, to: dy)
        addSpring("transform.scale", from: fromS, to: s)
    }

    /// 悬停高亮（持续态）：背景层明暗柔和渐变
    static func highlight(_ view: NSView, on: Bool, color: NSColor = NSColor(white: 1, alpha: 0.05)) {
        guard enabled, !reduceMotion else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        layer.backgroundColor = on ? color.cgColor : NSColor.clear.cgColor
        CATransaction.commit()
    }
}
