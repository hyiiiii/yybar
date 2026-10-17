import AppKit
import CoreText

// yybar app icon: macOS icon-grid rounded square (824pt, radius 185) on a light gradient,
// two playing cards fanned in a V — GPT as the black ace (OpenAI mark), Claude as the red ace (peach starburst).
// 两张牌整体放大 1.18 倍(占图标宽约 84%)。16 / 32 像素省掉角标，只留中间的大花色。
// 用法：swift scripts/make_app_icon.swift <输出目录>,再把 icon_*.png 拷进 Resources/Assets.xcassets/AppIcon.appiconset/
// logo 取自 Resources/Logos/{codex,claude}.svg。

let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let logoDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/Logos", isDirectory: true)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func fill(_ ctx: CGContext, _ path: CGPath, _ color: CGColor) {
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
}

func fillGradient(_ ctx: CGContext, path: CGPath, colors: [CGColor], from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

// MARK: Logos

struct Suit {
    let logo: NSImage
    let color: NSColor
    /// OpenAI 标志比 Claude 星芒视觉上更重，略缩小。
    let scale: CGFloat
    /// 图形可见部分中心相对图片中心的偏移(比例)。SVG 留白不对称，按可见部分居中。
    let offset: CGPoint
}

func visualOffset(_ image: NSImage) -> CGPoint {
    let n = 256
    let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    image.draw(in: CGRect(x: 0, y: 0, width: n, height: n))
    NSGraphicsContext.restoreGraphicsState()
    let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var minX = n, maxX = 0, minY = n, maxY = 0
    for y in 0..<n {
        for x in 0..<n where data[(y * n + x) * 4 + 3] > 20 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    // 位图第 0 行在上。
    return CGPoint(x: (CGFloat(minX + maxX) / 2 - CGFloat(n) / 2) / CGFloat(n),
                   y: -(CGFloat(minY + maxY) / 2 - CGFloat(n) / 2) / CGFloat(n))
}

func suit(_ name: String, color: NSColor, scale: CGFloat) -> Suit {
    let image = NSImage(contentsOf: logoDir.appendingPathComponent("\(name).svg"))!
    return Suit(logo: image, color: color, scale: scale, offset: visualOffset(image))
}

let gpt = suit("codex", color: NSColor(cgColor: rgb(0x111111))!, scale: 0.92)
let claude = suit("claude", color: NSColor(cgColor: rgb(0xD97757))!, scale: 1.0)

/// 单色 logo 按花色颜色画在 rect 里(按可见部分居中)。
func drawLogo(_ ctx: CGContext, _ suit: Suit, in rawRect: CGRect) {
    let rect = rawRect.offsetBy(dx: -suit.offset.x * rawRect.width, dy: -suit.offset.y * rawRect.height)
    let tinted = NSImage(size: suit.logo.size, flipped: false) { r in
        suit.logo.draw(in: r)
        suit.color.set()
        r.fill(using: .sourceAtop)
        return true
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    tinted.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
}

// MARK: Card

let cardSize = CGSize(width: 296, height: 414)

/// 一张 A:牌面、中间大花色;detail 时加左上 / 右下(倒置)的「A + 小花色」角标。
func drawCard(_ ctx: CGContext, center: CGPoint, degrees: CGFloat, suit: Suit, detail: Bool) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: degrees * .pi / 180)
    let rect = CGRect(x: -cardSize.width / 2, y: -cardSize.height / 2, width: cardSize.width, height: cardSize.height)
    let card = CGPath(roundedRect: rect, cornerWidth: 36, cornerHeight: 36, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: rgb(0x000000, 0.22))
    fill(ctx, card, rgb(0xFFFFFF))
    ctx.restoreGState()
    fillGradient(ctx, path: card, colors: [rgb(0xFFFFFF), rgb(0xF4F1EC)],
                 from: CGPoint(x: 0, y: rect.maxY), to: CGPoint(x: 0, y: rect.minY))
    ctx.saveGState()
    ctx.addPath(card)
    ctx.setStrokeColor(rgb(0x000000, 0.10))
    ctx.setLineWidth(2.5)
    ctx.strokePath()
    ctx.restoreGState()

    let big = 158 * suit.scale
    drawLogo(ctx, suit, in: CGRect(x: -big / 2, y: -big / 2, width: big, height: big))

    if detail {
        let serifDescriptor = NSFont.systemFont(ofSize: 64, weight: .bold).fontDescriptor.withDesign(.serif)!
        let serif = NSFont(descriptor: serifDescriptor, size: 64)!
        for flipped in [false, true] {
            ctx.saveGState()
            if flipped { ctx.rotate(by: .pi) }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "A", attributes: [.font: serif, .foregroundColor: suit.color]))
            ctx.textPosition = .zero   // 图像边界会带上当前文字位置，先归零
            let bounds = CTLineGetImageBounds(line, ctx)
            let cx = rect.minX + 42
            ctx.textPosition = CGPoint(x: cx - bounds.midX, y: rect.maxY - 30 - bounds.maxY)
            CTLineDraw(line, ctx)
            let pip = 40 * suit.scale
            drawLogo(ctx, suit, in: CGRect(x: cx - pip / 2, y: rect.maxY - 30 - bounds.height - 14 - pip, width: pip, height: pip))
            ctx.restoreGState()
        }
    }
    ctx.restoreGState()
}

// MARK: Icon

func render(size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(size) / 1024
    ctx.scaleBy(x: k, y: k)   // draw in a 1024 grid, origin bottom-left

    // Tile: 824pt in a 1024 canvas, light gradient, soft drop shadow.
    let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    // Apple 图标网格:824pt 圆角矩形，圆角 185pt(直边，不像纯超椭圆那样鼓)。
    let tile = CGPath(roundedRect: tileRect, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.30))
    fill(ctx, tile, rgb(0xE2E2E8))
    ctx.restoreGState()
    fillGradient(ctx, path: tile, colors: [rgb(0xFFFFFF), rgb(0xF1F1F4), rgb(0xE2E2E8)],
                 from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))

    // Two cards, scaled 1.18× around the center (nudged down 6pt): GPT behind on the left, Claude in front on the right.
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 506)
    ctx.scaleBy(x: 1.18, y: 1.18)
    ctx.translateBy(x: -512, y: -512)
    let detail = size >= 64
    drawCard(ctx, center: CGPoint(x: 394, y: 522), degrees: 9, suit: gpt, detail: detail)
    drawCard(ctx, center: CGPoint(x: 630, y: 506), degrees: -8, suit: claude, detail: detail)
    ctx.restoreGState()

    // Hairline edge.
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.setStrokeColor(rgb(0x000000, 0.08))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()

    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    try! render(size: size).write(to: outDir.appendingPathComponent("icon_\(size).png"))
}
print("ok")
