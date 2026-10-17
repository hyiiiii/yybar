import SwiftUI
import AppKit
import CoreText

// MARK: - TokenHeat
//
// Token 活动热力图和概览「今天」火苗共用的分档：最近 53 周(按周一开头对齐)里有用量的日子，
// 按 25% / 50% / 75% 分位分成 1~4 档;没用量为 0 档。

enum TokenHeat {
    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        cal.firstWeekday = 2
        return cal
    }

    /// 热力图最左一列(52 周前那一周的周一)。
    static func windowStart(now: Date = Date()) -> Date {
        let cal = calendar
        let today = cal.startOfDay(for: now)
        let thisWeek = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)) ?? today
        return cal.date(byAdding: .weekOfYear, value: -52, to: thisWeek) ?? thisWeek
    }

    static func thresholds(daily: [Date: Int], since start: Date) -> [Int] {
        let nonZero = daily.filter { $0.key >= start && $0.value > 0 }.values.sorted()
        guard !nonZero.isEmpty else { return [] }
        return [0.25, 0.5, 0.75].map { nonZero[min(nonZero.count - 1, Int(Double(nonZero.count) * $0))] }
    }

    static func level(_ value: Int, thresholds: [Int]) -> Int {
        guard value > 0 else { return 0 }
        guard thresholds.count == 3 else { return 4 }
        if value <= thresholds[0] { return 1 }
        if value <= thresholds[1] { return 2 }
        if value <= thresholds[2] { return 3 }
        return 4
    }
}

// MARK: - TodayFlame
//
// 概览「今天」标题旁的小火苗：今天全部 Token 越多档位越高——颜色越深、烧得越旺、3 档起冒火星。
// 直接用 🔥:1~3 档按像素明暗映射到该档的「外焰 → 中焰 → 内焰 → 高光」四色，4 档保留原生颜色。
// 燃烧：按向上流动的噪声扰动取样位置，底部不动、越往火尖扰动越大，火舌会自己舔动、分叉。
// 噪声在时间方向上是周期的，每档预先算好一整段首尾相接的循环帧(5~9 秒，每秒 24 帧，34 × 43 像素),
// 交给 Core Animation 循环播放——App 自己不再每帧计算，滚出视野或窗口在后台也不占 CPU。
// 0 档(今天还没用)只有一个灰色小炭点。

struct TodayFlame: View {
    let level: Int

    /// 火苗宽度(pt);高度留出 25% 给火舌往上窜。
    static let width: CGFloat = 17
    static let height: CGFloat = width * 1.25
    /// 火苗底部到视图底部的距离(pt),用于和标题文字底部对齐。
    static let baseInset: CGFloat = width * 0.1

    var body: some View {
        Group {
            if level <= 0 {
                Ellipse()
                    .fill(Color.primary.opacity(0.14))
                    .frame(width: 9, height: 3)
                    .frame(width: Self.width, height: Self.height, alignment: .bottom)
                    .padding(.bottom, Self.baseInset - 1)
            } else {
                // 动画放在 AppKit 视图里直接换图层内容：不走 SwiftUI 的刷新，不会带动整个统计页重新布局。
                FlameLayerView(level: level)
            }
        }
        .frame(width: Self.width, height: Self.height)
    }
}

private struct FlameLayerView: NSViewRepresentable {
    let level: Int

    func makeNSView(context: Context) -> FlameNSView { FlameNSView(level: level) }

    func updateNSView(_ view: FlameNSView, context: Context) { view.level = level }
}

/// 火苗图层：FlameRenderer 预先算好的循环帧用 CAKeyframeAnimation(discrete)逐帧播放，在系统渲染进程里换帧，
/// 不经过 App 的主线程，也不会让 AppKit / SwiftUI 重绘或重新布局。
/// 3 档起的火星同样是 Core Animation 图层动画。
final class FlameNSView: NSView {
    var level: Int {
        didSet {
            guard level != oldValue else { return }
            rebuildSparks()
            startBurning()
        }
    }

    private let flameLayer = CALayer()
    private var sparkLayers: [CALayer] = []

    private static let sparkSeeds: [(dx: CGFloat, delay: CFTimeInterval)] = [(-3, 0), (4, 0.4), (-6, 0.7), (6, 0.2)]

    init(level: Int) {
        self.level = level
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = false
        flameLayer.contentsGravity = .resize
        flameLayer.contentsScale = FlameRenderer.scale
        layer?.addSublayer(flameLayer)
        rebuildSparks()
        startBurning()
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 视图离开过窗口时动画可能被移除，回来时补上。
        if window != nil, flameLayer.animation(forKey: "burn") == nil { startBurning() }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flameLayer.frame = bounds
        CATransaction.commit()
        layoutSparks()
    }

    private func startBurning() {
        let loop = FlameRenderer.renderer(for: level).loop
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flameLayer.removeAnimation(forKey: "burn")
        flameLayer.contents = loop.frames.first
        CATransaction.commit()
        guard loop.frames.count > 1, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let burn = CAKeyframeAnimation(keyPath: "contents")
        burn.values = loop.frames
        burn.calculationMode = .discrete
        burn.duration = loop.duration
        burn.repeatCount = .infinity
        flameLayer.add(burn, forKey: "burn")
    }

    // MARK: Sparks

    private func rebuildSparks() {
        sparkLayers.forEach { $0.removeFromSuperlayer() }
        sparkLayers = []
        let count = level >= 4 ? 4 : (level == 3 ? 2 : 0)
        let now = CACurrentMediaTime()
        for seed in Self.sparkSeeds.prefix(count) {
            let spark = CALayer()
            spark.bounds = CGRect(x: 0, y: 0, width: 3, height: 3)
            spark.cornerRadius = 1.5
            spark.backgroundColor = NSColor(srgbRed: 1.0, green: 0.79, blue: 0.30, alpha: 1).cgColor
            spark.opacity = 0
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = 0
            rise.toValue = 22
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.95
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [rise, fade]
            group.duration = 1.25
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.beginTime = now + seed.delay
            group.fillMode = .backwards
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                spark.add(group, forKey: "spark")
            }
            layer?.addSublayer(spark)
            sparkLayers.append(spark)
        }
        layoutSparks()
    }

    /// 火星从火苗中上部(离底 58%)出发往上飘，可以超出视图边界。图层坐标 y 向上。
    private func layoutSparks() {
        for (spark, seed) in zip(sparkLayers, Self.sparkSeeds) {
            spark.position = CGPoint(x: bounds.midX + seed.dx, y: bounds.height * 0.58)
        }
    }
}

// MARK: - FlameRenderer

/// 一个档位的火苗：预先把 🔥 画进位图并按档位调色，再按扰动取样算出一整段循环帧。按档位缓存。
final class FlameRenderer {
    static let scale: CGFloat = 2
    static let fps: Double = 24
    /// 噪声时间方向的周期(噪声坐标单位)。fbm 两级频率 1 和 2.1,对应格点周期 10 和 21,
    /// 时间走完 10 两级都回到原处，最后一帧接回第一帧没有跳变。
    static let loopPeriod: Float = 10

    private static var cache: [Int: FlameRenderer] = [:]

    static func renderer(for level: Int) -> FlameRenderer {
        if let cached = cache[level] { return cached }
        let renderer = FlameRenderer(level: level)
        cache[level] = renderer
        return renderer
    }

    private struct Style {
        /// 外焰 / 中焰 / 内焰 / 高光;nil = 原生 🔥 颜色。
        let colors: [UInt32]?
        /// 🔥 字号占火苗宽度的比例(档位越高火越大)。
        let glyph: CGFloat
        /// 扰动强度 / 噪声上升速度。
        let amp: Float
        let rise: Float
    }

    private static let styles: [Int: Style] = [
        1: Style(colors: [0xFFA41C, 0xFFC23D, 0xFFE694, 0xFFFAEB], glyph: 0.80, amp: 0.55, rise: 1.10),
        2: Style(colors: [0xFF8414, 0xFFAA2E, 0xFFD86B, 0xFFF5D4], glyph: 0.86, amp: 0.70, rise: 1.35),
        3: Style(colors: [0xFF6A13, 0xFF9A1F, 0xFFD04D, 0xFFF3C4], glyph: 0.92, amp: 0.85, rise: 1.60),
        4: Style(colors: nil, glyph: 0.98, amp: 1.00, rise: 1.90)
    ]

    private let width: Int
    private let height: Int
    private let size: Float            // 火苗宽度(像素)
    private let base: Float            // 火苗底部所在行
    private let top: Float             // 火尖附近所在行
    private let style: Style
    private let seed: Float
    /// 预乘 RGBA,行从上往下。
    private var source: [UInt8]
    private var output: [UInt8]

    private init(level: Int) {
        style = Self.styles[level] ?? Self.styles[4]!
        let s = TodayFlame.width * Self.scale
        width = Int(s.rounded())
        height = Int((TodayFlame.height * Self.scale).rounded())
        size = Float(s)
        base = Float(CGFloat(height) - TodayFlame.baseInset * Self.scale)
        top = base - Float(s) * 0.95
        seed = Float(level) * 13.7
        source = Self.drawGlyph(width: width, height: height, fontSize: s * style.glyph, baselineFromBottom: TodayFlame.baseInset * Self.scale)
        output = [UInt8](repeating: 0, count: width * height * 4)
        if let colors = style.colors { recolor(colors) }
    }

    /// 用 CoreText 把 🔥 画到位图上，基线距底部 baselineFromBottom 像素，水平居中。
    private static func drawGlyph(width: Int, height: Int, fontSize: CGFloat, baselineFromBottom: CGFloat) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            let font = CTFontCreateWithName("AppleColorEmoji" as CFString, fontSize, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "🔥", attributes: [.font: font]))
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            ctx.textPosition = CGPoint(x: (CGFloat(width) - lineWidth) / 2, y: baselineFromBottom)
            CTLineDraw(line, ctx)
        }
        return pixels
    }

    /// 按亮度映射到该档四色(t = 亮度 0.38~0.98 → 外焰 … 高光),保留原 alpha。
    private func recolor(_ colors: [UInt32]) {
        let stops = colors.map { (Float(($0 >> 16) & 0xFF), Float(($0 >> 8) & 0xFF), Float($0 & 0xFF)) }
        for i in stride(from: 0, to: source.count, by: 4) {
            let a = Float(source[i + 3])
            guard a > 0 else { continue }
            let r = Float(source[i]) * 255 / a, g = Float(source[i + 1]) * 255 / a, b = Float(source[i + 2]) * 255 / a
            let lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
            let t = min(1, max(0, (lum - 0.38) / 0.6)) * 3
            let k = min(2, Int(t)), f = t - Float(k)
            let lo = stops[k], hi = stops[k + 1]
            source[i] = UInt8(min(255, (lo.0 + (hi.0 - lo.0) * f) * a / 255))
            source[i + 1] = UInt8(min(255, (lo.1 + (hi.1 - lo.1) * f) * a / 255))
            source[i + 2] = UInt8(min(255, (lo.2 + (hi.2 - lo.2) * f) * a / 255))
        }
    }

    /// 一整段循环：噪声时间走一个周期(档位越高上升越快，循环越短：4 档约 5.3 秒，1 档约 9.1 秒),每秒 24 帧。
    private(set) lazy var loop: (frames: [CGImage], duration: CFTimeInterval) = {
        let duration = Double(Self.loopPeriod / style.rise)
        let count = max(1, Int((duration * Self.fps).rounded()))
        let frames = (0..<count).compactMap { frame(t: seed + Self.loopPeriod * Float($0) / Float(count)) }
        return (frames, duration)
    }()

    /// 噪声时间为 t 的一帧。
    private func frame(t: Float) -> CGImage? {
        let flick = 0.92 + 0.08 * Self.noise(t * 3.1, 7.7, periodX: 31)   // 整体明暗闪烁(t 走 10,x 走 31 个格点)
        let w = width, h = height
        let span = max(1, base - top)
        for y in 0..<h {
            let up = min(1, max(0, (base - Float(y)) / span))
            let k = style.amp * pow(up, 1.5)                          // 越往上扰动越大，底部不动
            let fade = 1 - pow(up, 3) * 0.35
            for x in 0..<w {
                let di = (y * w + x) * 4
                if k == 0 {
                    output[di] = source[di]; output[di + 1] = source[di + 1]; output[di + 2] = source[di + 2]; output[di + 3] = source[di + 3]
                    continue
                }
                let nx = Float(x) / size * 2.0, ny = Float(y) / size * 1.7 + t   // 噪声向上流动
                let n1 = Self.fbm(nx, ny), n2 = Self.fbm(nx + 41.3, ny + 17.1)
                let fx = Float(x) + (n1 - 0.5) * k * size * 0.3
                let fy = Float(y) + (n2 - 0.32) * k * size * 0.24            // 偏向从下方取样 → 火舌往上舔
                // 双线性采样(预乘颜色直接插值)
                let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
                let ax = fx - Float(x0), ay = fy - Float(y0)
                var acc: (Float, Float, Float, Float) = (0, 0, 0, 0)
                for j in 0..<4 {
                    let sx = x0 + (j & 1), sy = y0 + (j >> 1)
                    guard sx >= 0, sx < w, sy >= 0, sy < h else { continue }
                    let wt = ((j & 1) == 1 ? ax : 1 - ax) * ((j >> 1) == 1 ? ay : 1 - ay)
                    let si = (sy * w + sx) * 4
                    acc.0 += Float(source[si]) * wt; acc.1 += Float(source[si + 1]) * wt
                    acc.2 += Float(source[si + 2]) * wt; acc.3 += Float(source[si + 3]) * wt
                }
                let alphaScale = 1 - (1 - fade) * n1                        // 火尖末端燃尽变淡
                let a = min(255, acc.3 * alphaScale)
                output[di + 3] = UInt8(a)
                output[di] = UInt8(min(a, acc.0 * alphaScale * flick))
                output[di + 1] = UInt8(min(a, acc.1 * alphaScale * flick))
                output[di + 2] = UInt8(min(a, acc.2 * alphaScale * flick))
            }
        }
        let data = Data(output) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Noise

    private static func hash(_ x: Int32, _ y: Int32) -> Float {
        var h = UInt32(bitPattern: x &* 374_761_393 &+ y &* 668_265_263)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        return Float(h ^ (h >> 16)) / Float(UInt32.max)
    }

    /// 值噪声。periodX / periodY 非 0 时格点在该方向上按周期重复(用于让循环帧首尾相接)。
    private static func noise(_ x: Float, _ y: Float, periodX: Int32 = 0, periodY: Int32 = 0) -> Float {
        let xf0 = x.rounded(.down), yf0 = y.rounded(.down)
        let xi = Int32(truncatingIfNeeded: Int(xf0)), yi = Int32(truncatingIfNeeded: Int(yf0))
        let xf = x - xf0, yf = y - yf0
        func wrap(_ i: Int32, _ period: Int32) -> Int32 { period > 0 ? ((i % period) + period) % period : i }
        func h(_ i: Int32, _ j: Int32) -> Float { hash(wrap(i, periodX), wrap(j, periodY)) }
        let a = h(xi, yi), b = h(xi &+ 1, yi), c = h(xi, yi &+ 1), d = h(xi &+ 1, yi &+ 1)
        let u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf)
        return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v
    }

    /// y 是时间方向(噪声向上流动),两级分别以 10、21 个格点为周期，对应时间周期 loopPeriod。
    private static func fbm(_ x: Float, _ y: Float) -> Float {
        noise(x, y, periodY: 10) * 0.75 + noise(x * 2.1, y * 2.1, periodY: 21) * 0.25
    }
}

// MARK: - HotFlameIcon
//
// 模型明细「最热」模型旁的小火苗(SF Symbol flame.fill,上红下橙渐变)。
// 循环动画：起跳拉长 + 左倾 → 落地压扁 → 右摇 → 复位(约 0.84 秒一轮),以底部为原点。
// 用 Core Animation 关键帧在系统渲染进程里跑，不占主线程，也不触发 SwiftUI 重新布局。

struct HotFlameIcon: NSViewRepresentable {
    func makeNSView(context: Context) -> HotFlameNSView { HotFlameNSView() }
    func updateNSView(_ view: HotFlameNSView, context: Context) {}
}

final class HotFlameNSView: NSView {
    private let flame = CALayer()

    private static let image: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
        let symbol = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
        return NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSGraphicsContext.current?.compositingOperation = .sourceIn
            // 下橙上红
            NSGradient(starting: NSColor(srgbRed: 1.0, green: 0.66, blue: 0.12, alpha: 1),
                       ending: NSColor(srgbRed: 1.0, green: 0.27, blue: 0.2, alpha: 1))?.draw(in: rect, angle: 90)
            return true
        }
    }()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        flame.contents = Self.image
        flame.contentsGravity = .resizeAspect
        flame.anchorPoint = CGPoint(x: 0.5, y: 0)          // 以底部为原点变形
        layer?.addSublayer(flame)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { flame.add(Self.animation(), forKey: "hot") }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        flame.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flame.bounds = CGRect(origin: .zero, size: Self.image.size)
        flame.position = CGPoint(x: bounds.midX, y: max(0, (bounds.height - Self.image.size.height) / 2))
        CATransaction.commit()
    }

    /// 图层坐标 y 向上：上抬为正，逆时针为正(对应原 SwiftUI 版本的左倾 -6° / 右摇 +5°)。
    private static func animation() -> CAAnimation {
        func pose(sx: CGFloat, sy: CGFloat, lift: CGFloat, degrees: CGFloat) -> NSValue {
            var t = CATransform3DMakeTranslation(0, lift, 0)
            t = CATransform3DRotate(t, degrees * .pi / 180, 0, 0, 1)
            t = CATransform3DScale(t, sx, sy, 1)
            return NSValue(caTransform3D: t)
        }
        let rest = pose(sx: 1, sy: 1, lift: 0, degrees: 0)
        let keyframes = CAKeyframeAnimation(keyPath: "transform")
        keyframes.values = [rest,
                            pose(sx: 0.9, sy: 1.16, lift: 1.5, degrees: 6),
                            pose(sx: 1.08, sy: 0.9, lift: 0, degrees: 0),
                            pose(sx: 0.96, sy: 1.06, lift: 0.5, degrees: -5),
                            rest]
        let total = 0.22 + 0.16 + 0.2 + 0.26
        keyframes.keyTimes = [0, 0.22 / total, 0.38 / total, 0.58 / total, 1].map { NSNumber(value: $0) }
        keyframes.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn),
                                     CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        keyframes.duration = total
        keyframes.repeatCount = .infinity
        return keyframes
    }
}
