import AppKit
import QuartzCore
import CoreImage

// MARK: - 悬停浮起按钮
// 鼠标移入：轻微放大浮起 + 高亮；移出：落下还原。全局统一交互语言。

class HoverEffectButton: NSButton {
    /// 悬停放大档：1.12 + 更亮的高亮层——「触感更强」的手感基准，全局按钮统一
    var hoverScale: CGFloat = 1.12
    private var tracking: NSTrackingArea?

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

// MARK: - 虚化渐入动效（blur-in reveal）
// 规格：A 档——0.35s 入场过渡，透明度 0.55→1 + 高斯模糊 6px→0，ease-out，无位移无缩放。
// 遵循系统「减弱动态效果」；TestRender 置 enabled=false 保证截图与断言同步。

enum Motion {
    /// 全局开关：测试环境置 false（所有动效直通最终态）
    static var enabled = true
    /// 动效时长常量（集中调参）：A 档
    static let revealDuration: TimeInterval = 0.35
    static let startAlpha: CGFloat = 0.55
    static let startBlur: Double = 6.0

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// 虚化渐入（窗口）：透明度 + 高斯模糊过渡（几何不动）
    static func reveal(_ window: NSWindow, duration: TimeInterval = revealDuration) {
        guard enabled, !reduceMotion else { return }
        window.alphaValue = startAlpha
        armBlur(window.contentView, duration: duration)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1.0
        }, completionHandler: {
            window.contentView?.layer?.filters = nil
        })
    }

    /// 虚化渐入（视图）：透明度 + 高斯模糊过渡（视图几何不动）
    static func reveal(_ view: NSView, duration: TimeInterval = revealDuration) {
        guard enabled, !reduceMotion else { return }
        view.alphaValue = startAlpha
        armBlur(view, duration: duration)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = 1.0
        }, completionHandler: {
            view.layer?.filters = nil
        })
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

    /// 挂载高斯模糊滤镜并播放半径衰减动画
    private static func armBlur(_ view: NSView?, duration: TimeInterval) {
        guard enabled, !reduceMotion, let view else { return }
        view.wantsLayer = true
        view.layerUsesCoreImageFilters = true
        guard let layer = view.layer, let blur = CIFilter(name: "CIGaussianBlur") else { return }
        blur.setValue(startBlur, forKey: kCIInputRadiusKey)
        layer.filters = [blur]
        let anim = CABasicAnimation(keyPath: "filters.gaussianBlur.inputRadius")
        anim.fromValue = startBlur
        anim.toValue = 0.0
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: "motionBlurIn")
    }
}
