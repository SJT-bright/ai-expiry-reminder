// App 图标生成器：深色玻璃砖 + 沙漏（上层绿沙 → 下层红沙 = 倒计时临近到期）
// 用法: swift Assets/make_icon.swift <输出iconset目录>
// 产物为 macOS iconset 全尺寸 PNG，随后用 iconutil -c icns 打包。
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// 沙漏几何（1024 画布）：鼓腹瓶身 + 40pt 沙颈
let cx: CGFloat = 512
let capTopY: CGFloat = 726      // 上瓶盖内侧
let capBotY: CGFloat = 302      // 下瓶盖内侧
let neckY: CGFloat = 514        // 腰部
let neckHalf: CGFloat = 20      // 颈半宽
let bulbW: CGFloat = 165        // 瓶腹半宽

// 整体玻璃轮廓（描边用）
let outline = { () -> CGPath in
    let p = CGMutablePath()
    p.move(to: CGPoint(x: cx - bulbW, y: capTopY))
    p.addLine(to: CGPoint(x: cx + bulbW, y: capTopY))
    p.addCurve(to: CGPoint(x: cx + neckHalf, y: neckY),
               control1: CGPoint(x: cx + bulbW + 10, y: 600), control2: CGPoint(x: cx + 63, y: 530))
    p.addCurve(to: CGPoint(x: cx + bulbW, y: capBotY),
               control1: CGPoint(x: cx + 63, y: 498), control2: CGPoint(x: cx + bulbW + 10, y: 428))
    p.addLine(to: CGPoint(x: cx - bulbW, y: capBotY))
    p.addCurve(to: CGPoint(x: cx - neckHalf, y: neckY),
               control1: CGPoint(x: cx - bulbW - 10, y: 428), control2: CGPoint(x: cx - 63, y: 498))
    p.addCurve(to: CGPoint(x: cx - bulbW, y: capTopY),
               control1: CGPoint(x: cx - 63, y: 530), control2: CGPoint(x: cx - bulbW - 10, y: 600))
    p.closeSubpath()
    return p
}()

// 单只瓶（裁剪用，闭合）
let topBulb = { () -> CGPath in
    let p = CGMutablePath()
    p.move(to: CGPoint(x: cx - bulbW, y: capTopY))
    p.addLine(to: CGPoint(x: cx + bulbW, y: capTopY))
    p.addCurve(to: CGPoint(x: cx + neckHalf, y: neckY),
               control1: CGPoint(x: cx + bulbW + 10, y: 600), control2: CGPoint(x: cx + 63, y: 530))
    p.addLine(to: CGPoint(x: cx - neckHalf, y: neckY))
    p.addCurve(to: CGPoint(x: cx - bulbW, y: capTopY),
               control1: CGPoint(x: cx - 63, y: 530), control2: CGPoint(x: cx - bulbW - 10, y: 600))
    p.closeSubpath()
    return p
}()
let botBulb = { () -> CGPath in
    let p = CGMutablePath()
    p.move(to: CGPoint(x: cx + neckHalf, y: neckY))
    p.addCurve(to: CGPoint(x: cx + bulbW, y: capBotY),
               control1: CGPoint(x: cx + 63, y: 498), control2: CGPoint(x: cx + bulbW + 10, y: 428))
    p.addLine(to: CGPoint(x: cx - bulbW, y: capBotY))
    p.addCurve(to: CGPoint(x: cx - neckHalf, y: neckY),
               control1: CGPoint(x: cx - bulbW - 10, y: 428), control2: CGPoint(x: cx - 63, y: 498))
    p.closeSubpath()
    return p
}()

func draw(size: Int) -> CGImage {
    let s = CGFloat(size) / 1024.0
    let ctx = CGContext(data: nil, width: size, height: size,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    // ── 圆角方砖（macOS 大苏尔网格：1024 画布内 824×824，圆角 ~22.4%）──
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let radius: CGFloat = 185
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    // 底色：深灰蓝垂直渐变（呼应悬浮窗深色 HUD 玻璃）
    let bg = CGGradient(colorsSpace: nil, colors: [
        CGColor(red: 0.16, green: 0.16, blue: 0.19, alpha: 1),
        CGColor(red: 0.085, green: 0.085, blue: 0.105, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // 顶部微高光（玻璃反光）
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 100, y: 512, width: 824, height: 412))
    let gloss = CGGradient(colorsSpace: nil, colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.07),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 512), options: [])
    ctx.restoreGState()

    // 内描边高光
    ctx.setLineWidth(3)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 4, dy: 4), cornerWidth: radius - 4, cornerHeight: radius - 4, transform: nil))
    ctx.strokePath()
    ctx.restoreGState()

    // ── 沙漏 ──
    ctx.saveGState()
    let glassStroke = CGColor(red: 0.92, green: 0.93, blue: 0.97, alpha: 0.6)
    let glassFill = CGColor(red: 1, green: 1, blue: 1, alpha: 0.07)

    // 玻璃：填充 + 描边
    ctx.addPath(outline)
    ctx.setFillColor(glassFill)
    ctx.fillPath()
    ctx.addPath(outline)
    ctx.setStrokeColor(glassStroke)
    ctx.setLineWidth(13)
    ctx.strokePath()

    let green = CGColor(red: 0.20, green: 0.80, blue: 0.36, alpha: 1)
    let red = CGColor(red: 1.0, green: 0.30, blue: 0.28, alpha: 1)

    // 上瓶绿沙（剩余充裕）：平顶沙面 + 漏斗状收向沙颈
    ctx.saveGState()
    ctx.addPath(topBulb)
    ctx.clip()
    let topSand = CGMutablePath()
    topSand.move(to: CGPoint(x: cx - 200, y: 688))
    topSand.addLine(to: CGPoint(x: cx + 200, y: 688))
    topSand.addCurve(to: CGPoint(x: cx + neckHalf, y: 518),
                     control1: CGPoint(x: cx + 110, y: 608), control2: CGPoint(x: cx + 56, y: 545))
    topSand.addLine(to: CGPoint(x: cx - neckHalf, y: 518))
    topSand.addCurve(to: CGPoint(x: cx - 200, y: 688),
                     control1: CGPoint(x: cx - 56, y: 545), control2: CGPoint(x: cx - 110, y: 608))
    topSand.closeSubpath()
    ctx.addPath(topSand)
    ctx.setFillColor(green)
    ctx.fillPath()
    ctx.restoreGState()

    // 沙流：绿→红 渐变细流（画在沙堆之下，被沙堆自然覆盖下端）
    ctx.saveGState()
    ctx.addPath(CGPath(rect: CGRect(x: cx - 7, y: 345, width: 14, height: 172), transform: nil))
    ctx.clip()
    let flow = CGGradient(colorsSpace: nil, colors: [green, red] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(flow, start: CGPoint(x: cx, y: 517), end: CGPoint(x: cx, y: 345), options: [])
    ctx.restoreGState()

    // 下瓶红沙（临近到期）：圆顶沙丘
    ctx.saveGState()
    ctx.addPath(botBulb)
    ctx.clip()
    let pile = CGMutablePath()
    pile.move(to: CGPoint(x: cx - 200, y: 268))
    pile.addLine(to: CGPoint(x: cx - 200, y: 330))
    pile.addCurve(to: CGPoint(x: cx + 200, y: 330),
                  control1: CGPoint(x: cx - 95, y: 462), control2: CGPoint(x: cx + 95, y: 462))
    pile.addLine(to: CGPoint(x: cx + 200, y: 268))
    pile.closeSubpath()
    ctx.addPath(pile)
    ctx.setFillColor(red)
    ctx.fillPath()
    ctx.restoreGState()

    // 上下瓶盖（金属横杆）
    let capGrad = CGGradient(colorsSpace: nil, colors: [
        CGColor(red: 0.93, green: 0.93, blue: 0.96, alpha: 1),
        CGColor(red: 0.62, green: 0.63, blue: 0.70, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    for y in [756.0, 272.0] {
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: CGRect(x: 296, y: y, width: 432, height: 30), cornerWidth: 15, cornerHeight: 15, transform: nil))
        ctx.clip()
        ctx.drawLinearGradient(capGrad, start: CGPoint(x: 512, y: y + 30), end: CGPoint(x: 512, y: y), options: [])
        ctx.restoreGState()
    }

    ctx.restoreGState()
    return ctx.makeImage()!
}

func write(_ img: CGImage, _ name: String) {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

for (name, px) in [("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
                   ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
                   ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
                   ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
                   ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)] {
    write(draw(size: px), name)
}
print("iconset → \(outDir)")
