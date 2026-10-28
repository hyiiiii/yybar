import SwiftUI

// MARK: - BarView
//
// 主窗口 · bar:和统计、设置都不同的独立页(见 docs/界面布局.md §3.0),不放标题和说明文字。
// 上面是一间像素风的木头小酒馆，直接画在页面上(不另起背景卡片):屋顶立着 yybar 跑马灯招牌，
// 门口站着 Claude 风格的像素小家伙招手;点酒馆任意处打开 yybar 网站的个人主页(YYBarWeb,/me;2026-10-28 前是德州大厅)。
// 下面是上传卡片：连接 GitHub、待上传 / 已上传、自动上传、一键上传(每天一次),逻辑在 YYBarWebAccount。

struct BarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // 点酒馆进网站的个人主页(悬停有提示)
                BarScene { NSWorkspace.shared.open(YYBarWeb.url.appendingPathComponent("me")) }
                    .frame(maxWidth: .infinity)
                BarUploadCard()
            }
            .padding(.horizontal, 24)
            .padding(.top, 36)
            .padding(.bottom, 20)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - 场景

/// 像素一格多大(pt)。小酒馆 104×70 格。
private let px: CGFloat = 4
private let sceneW = 104
private let sceneH = 70

private struct BarScene: View {
    let enter: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 地面比酒馆宽一些，两头淡出，和页面接在一起
            GroundStrip()
                .frame(width: CGFloat(sceneW + 56) * px, height: 6 * px)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.2),
                                             .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
                .offset(x: -28 * px, y: 62 * px)
            PixelTavern()
                .frame(width: CGFloat(sceneW) * px, height: CGFloat(sceneH) * px)
            MarqueeSign()
                .frame(width: 42 * px, height: 15 * px)
                .offset(x: 31 * px, y: 0)
            // 脚踩在地面那一行(第 62 格)
            ClawdGreeter()
                .frame(width: 16 * px, height: 13 * px)
                .offset(x: 64 * px, y: 49 * px)
        }
        .frame(width: CGFloat(sceneW) * px, height: 68 * px, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture(perform: enter)
        .pointingHandCursor()
        .help(tr("Open my page on the yybar website", "打开 yybar 网站的个人主页"))
    }
}

/// 地面：一条石板路，上面一行草。
private struct GroundStrip: View {
    var body: some View {
        Canvas { ctx, size in
            let cols = Int(size.width / px) + 1
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.px(0x4A3E35)))
            ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: px)), with: .color(.px(0x5E7A3E)))
            for row in 0..<3 {
                for col in stride(from: (row % 2) * 3, to: cols, by: 6) {
                    ctx.fill(Path(CGRect(x: CGFloat(col) * px, y: CGFloat(1 + row * 2) * px, width: 4 * px, height: px)),
                             with: .color(.px(row == 0 ? 0x66574A : 0x5A4B3F)))
                }
            }
        }
    }
}

/// 小酒馆本体：屋顶、木板墙、门、两扇亮着的窗、灯笼、酒桶。坐标单位是像素格。
private struct PixelTavern: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let flicker = Int(context.date.timeIntervalSinceReferenceDate * 2) % 3
            Canvas { ctx, _ in
                func r(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: UInt32, _ a: Double = 1) {
                    ctx.fill(Path(CGRect(x: CGFloat(x) * px, y: CGFloat(y) * px, width: CGFloat(w) * px, height: CGFloat(h) * px)),
                             with: .color(.px(c).opacity(a)))
                }

                // 门口和灯笼的暖光(在墙前面晕开)
                let glow = Gradient(colors: [.px(0xFFC86E).opacity(0.45), .px(0xFFC86E).opacity(0)])
                // 整块铺(只铺到地面为止)，渐变自己淡到透明，不会留下椭圆的边
                ctx.fill(Path(CGRect(x: 0, y: 0, width: CGFloat(sceneW) * px, height: 62 * px)),
                         with: .radialGradient(glow, center: CGPoint(x: 52 * px, y: 54 * px), startRadius: 0, endRadius: 24 * px))

                // 招牌的两根立柱
                r(37, 14, 2, 6, 0x3A2213)
                r(65, 14, 2, 6, 0x3A2213)

                // 屋顶：梯形，两格一排瓦，错开的瓦缝
                for y in 14..<28 {
                    let inset = (27 - y) * 14 / 13
                    let left = 6 + inset, width = 92 - inset * 2
                    r(left, y, width, 1, (y / 2) % 2 == 0 ? 0x5A2F22 : 0x6A3727)
                    if y % 2 == 1 {
                        for x in stride(from: left + (y / 2) % 2 * 2, to: left + width, by: 5) { r(x, y, 1, 1, 0x44231A) }
                    }
                }
                r(20, 13, 64, 1, 0x7E4632) // 屋脊
                r(5, 28, 94, 1, 0x3A1D14) // 屋檐

                // 木板墙：4 格一块板，最下一行是板缝，接缝错开
                for i in 0..<8 {
                    let y = 29 + i * 4
                    r(16, y, 72, 3, i % 2 == 0 ? 0x9B6A3C : 0x8F6136)
                    r(16, y + 3, 72, 1, 0x6E4627)
                    for x in (i % 2 == 0 ? [30, 58, 78] : [22, 46, 70]) { r(x, y, 1, 3, 0x6E4627) }
                }
                r(14, 61, 76, 1, 0x4A2C18) // 墙脚的地梁，接上地面
                // 两侧立柱、顶梁
                r(14, 28, 3, 34, 0x4A2C18); r(15, 28, 1, 34, 0x5C3920)
                r(87, 28, 3, 34, 0x4A2C18); r(88, 28, 1, 34, 0x5C3920)

                // 窗：木框、暖黄玻璃、十字窗棂、花箱
                for wx in [22, 68] {
                    r(wx, 35, 14, 11, 0x3A2213)
                    r(wx + 1, 36, 12, 9, 0xFFD27F)
                    r(wx + 1, 36, 4, 2, 0xFFE6AE)
                    r(wx + 6, 36, 2, 9, 0x3A2213)
                    r(wx + 1, 40, 12, 1, 0x3A2213)
                    r(wx - 1, 46, 16, 2, 0x5C3920)
                    for (k, fx) in stride(from: wx, to: wx + 14, by: 2).enumerated() {
                        r(fx, 45, 1, 1, 0x5F8F3E)
                        r(fx + 1, 44, 1, 1, k % 2 == 0 ? 0xE2574C : 0xF2C14E)
                    }
                }

                // 门：拱形门框、门里的暖光、半开的门板
                r(45, 44, 14, 18, 0x3A2213)
                r(46, 43, 12, 1, 0x3A2213)
                r(47, 42, 10, 1, 0x3A2213)
                for y in 44..<61 {
                    r(46, y, 12, 1, y < 50 ? 0xFFD58A : y < 56 ? 0xF8BE69 : 0xF0A94A)
                }
                r(47, 43, 10, 1, 0xFFD58A)
                r(46, 44, 4, 17, 0x6B4226)
                r(47, 44, 1, 17, 0x4A2C18)
                r(49, 52, 1, 1, 0xF2C14E) // 门把手
                r(44, 61, 16, 1, 0x6E5C4B) // 台阶
                // 门里一张小桌和两把凳子的影子
                r(51, 55, 6, 1, 0x8A5530); r(53, 56, 2, 4, 0x8A5530)
                r(51, 58, 1, 2, 0x8A5530); r(56, 58, 1, 2, 0x8A5530)

                // 门边的灯笼：支架、灯身，火苗轻轻跳
                r(40, 39, 4, 1, 0x2A1A10)
                r(40, 40, 1, 1, 0x2A1A10)
                r(39, 41, 3, 5, 0x2A1A10)
                r(40, 42, 1, 3, flicker == 0 ? 0xFFE6AE : 0xFFD27F)

                // 酒桶和木箱
                r(24, 53, 8, 9, 0x8A5530)
                r(24, 53, 8, 1, 0xA36A3D)
                for x in [26, 29] { r(x, 54, 1, 8, 0x6E4224) }
                r(24, 55, 8, 1, 0x3D2B1F); r(24, 59, 8, 1, 0x3D2B1F)
                r(33, 57, 6, 5, 0x8A5A32)
                r(33, 57, 6, 1, 0x6E4627); r(33, 61, 6, 1, 0x6E4627)
                for k in 0..<4 { r(34 + k, 58 + k % 3, 1, 1, 0x6E4627) }

                // 门前地上的光
                r(44, 62, 16, 2, 0xF0A94A, 0.35)
                r(42, 64, 20, 1, 0xF0A94A, 0.18)
            }
        }
    }
}

/// 屋顶上的 yybar 跑马灯招牌：深色底板、一圈灯泡轮流亮、霓虹手写字，和网站上的招牌一致。
private struct MarqueeSign: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { context in
            let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 3
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.px(0x1F1E1D))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.px(0xB98463), lineWidth: 2))
                    Canvas { ctx, size in
                        for (i, p) in bulbPositions(w: size.width, h: size.height).enumerated() {
                            let lit = i % 3 == phase
                            let dot = CGRect(x: p.x - 2.6, y: p.y - 2.6, width: 5.2, height: 5.2)
                            if lit {
                                ctx.fill(Path(ellipseIn: dot.insetBy(dx: -3, dy: -3)), with: .color(.px(0xF4C16A).opacity(0.3)))
                            }
                            ctx.fill(Path(ellipseIn: dot), with: .color(.px(0xF4C16A).opacity(lit ? 1 : 0.35)))
                        }
                    }
                    Text("yybar")
                        .font(.custom("SnellRoundhand-Black", size: h * 0.62))
                        .foregroundStyle(Color.px(0xFFE7C7))
                        .shadow(color: .px(0xFFF4E0), radius: 1)
                        .shadow(color: .px(0xFFAA6E).opacity(0.9), radius: 5)
                        .shadow(color: .px(0xD97757).opacity(0.8), radius: 10)
                        .offset(y: -h * 0.04)
                }
                .frame(width: w, height: h)
            }
        }
    }

    private func bulbPositions(w: CGFloat, h: CGFloat) -> [CGPoint] {
        let inset: CGFloat = 7, step: CGFloat = 14
        var out: [CGPoint] = []
        var x = inset
        while x <= w - inset { out.append(CGPoint(x: x, y: inset)); x += step }
        var y = inset + step
        while y <= h - inset { out.append(CGPoint(x: w - inset, y: y)); y += step }
        x = w - inset - step
        while x >= inset { out.append(CGPoint(x: x, y: h - inset)); x -= step }
        y = h - inset - step
        while y > inset { out.append(CGPoint(x: inset, y: y)); y -= step }
        return out
    }
}

/// 门口招呼客人的像素小家伙(和网站发牌员同一个造型)：上下晃、眨眼、隔一会儿招手;鼠标移上去会笑。
private struct ClawdGreeter: View {
    @State private var hovering = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 12)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let blink = t.truncatingRemainder(dividingBy: 4.2) < 0.14
            let waving = hovering || t.truncatingRemainder(dividingBy: 5) < 1.6
            let armUp = waving && Int(t * 4) % 2 == 0
            let bob: CGFloat = Int(t * 2) % 2 == 0 ? 0 : -2
            ClawdSprite(blink: blink && !hovering, happy: hovering, armUp: armUp)
                .offset(y: bob)
        }
        .onHover { hovering = $0 }
    }
}

private struct ClawdSprite: View {
    let blink: Bool
    let happy: Bool
    let armUp: Bool

    var body: some View {
        Canvas { ctx, _ in
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: Color) {
                ctx.fill(Path(CGRect(x: x * px, y: y * px, width: w * px, height: h * px)), with: .color(c))
            }
            let skin = Color.px(0xD97757), ink = Color.px(0x141413)
            r(2, 1, 12, 8, skin)
            r(0, 4, 2, 2, skin)
            r(14, armUp ? 2 : 4, 2, 2, skin)
            for x in [3.0, 5, 10, 12] { r(x, 9, 1, 3, skin) }
            if happy {
                for ex in [4.6, 10.4] {
                    r(ex - 0.4, 4.4, 0.6, 0.5, ink); r(ex + 0.1, 3.9, 0.6, 0.5, ink); r(ex + 0.6, 4.4, 0.6, 0.5, ink)
                }
                r(3, 5.6, 1.4, 0.7, .px(0xF2A08A)); r(11.6, 5.6, 1.4, 0.7, .px(0xF2A08A))
            } else if blink {
                r(4.3, 4.4, 1.6, 0.45, ink); r(10.1, 4.4, 1.6, 0.45, ink)
            } else {
                r(4.6, 3, 1, 2, ink); r(10.4, 3, 1, 2, ink)
            }
        }
    }
}

// MARK: - 上传卡片

private struct BarUploadCard: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let account = appState.webAccount
        let source = YYBarWebAccount.Source(buckets: appState.usageService.aggregator.snapshot(), answers: appState.geminiAnswerLog.counts)
        let pending = account.pending(source)
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    label("GitHub")
                    accountRow(account)
                }
                GridRow {
                    label(tr("To upload", "待上传"))
                    if pending.days.isEmpty {
                        Text(tr("Nothing new — every finished day is in", "没有新的天：今天以前的都传过了")).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 6) {
                            Text(tr("\(pending.days.count) days · \(usd(pending.costUSD))", "\(pending.days.count) 天 · \(usd(pending.costUSD))"))
                                .monospacedDigit()
                            Text(tr("≈ \(pending.chips.formatted()) chips", "≈ \(pending.chips.formatted()) 筹码"))
                                .monospacedDigit()
                                .foregroundStyle(Color.px(0xC88A0E))
                            if pending.answers > 0 {
                                Text(tr("· Gemini \(pending.answers.formatted()) answers", "· Gemini \(pending.answers.formatted()) 次回答"))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                GridRow {
                    label(tr("Uploaded", "已上传"))
                    Text(uploadedText(account)).monospacedDigit().foregroundStyle(account.ledger.dayCount == 0 ? .secondary : .primary)
                }
                GridRow {
                    label(tr("Auto upload", "自动上传"))
                    Toggle(tr("Upload every day at 12:00", "每天 12:00 上传"),
                           isOn: Binding(get: { account.autoUpload }, set: { account.autoUpload = $0 }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!account.isConnected)
                }
            }
            .scaledFont(size: 12.5)

            HStack(spacing: 10) {
                Button {
                    account.uploadNow(source)
                } label: {
                    Label(uploadButtonTitle(account, pending: pending), systemImage: "arrow.up.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!account.isConnected || account.phase != .idle || account.usedManualUploadToday || pending.days.isEmpty)
                if account.phase == .uploading {
                    ProgressView().controlSize(.small)
                }
                if let message = account.message {
                    Text(message)
                        .scaledFont(size: 11.5)
                        .foregroundStyle(account.messageIsError ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .ccPanel()
    }

    @ViewBuilder
    private func accountRow(_ account: YYBarWebAccount) -> some View {
        HStack(spacing: 8) {
            if let profile = account.profile, account.isConnected {
                WebAvatar(profile: profile, size: 20)
                Text("@\(profile.login)").scaledFont(size: 12.5, weight: .medium)
                if let name = profile.name, !name.isEmpty, name != profile.login {
                    Text(name).foregroundStyle(.secondary)
                }
                Spacer()
                Button(tr("Disconnect", "断开")) { account.disconnect() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            } else if account.phase == .waitingForBrowser {
                ProgressView().controlSize(.small)
                Text(tr("Approve in your browser…", "在浏览器里授权…")).foregroundStyle(.secondary)
                Spacer()
                Button(tr("Cancel", "取消")) { account.cancelConnect() }
                    .buttonStyle(.borderless)
            } else {
                Text(tr("Not connected", "未连接")).foregroundStyle(.secondary)
                Spacer()
                Button(tr("Connect GitHub…", "连接 GitHub…")) { account.connect() }
            }
        }
    }

    private func uploadButtonTitle(_ account: YYBarWebAccount, pending: YYBarWebAccount.Pending) -> String {
        if account.phase == .uploading { return tr("Uploading…", "上传中…") }
        if account.usedManualUploadToday { return tr("Uploaded today", "今天已经上传过了") }
        return tr("Upload now", "一键上传")
    }

    private func uploadedText(_ account: YYBarWebAccount) -> String {
        let days = account.ledger.dayCount
        guard days > 0 else { return "—" }
        guard let last = account.ledger.lastUploadAt else { return tr("\(days) days", "\(days) 天") }
        let age = RelativeTime.short(from: last)
        return tr("\(days) days · last \(age) ago", "\(days) 天 · 上次 \(age) 前")
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.leading)
    }

    private func usd(_ value: Decimal) -> String {
        "$" + NSDecimalNumber(decimal: value).doubleValue.formatted(.number.precision(.fractionLength(2)))
    }
}

/// 连接的 GitHub 头像(圆形);图片没加载出来时是名字首字母。bar 页和侧边栏左下角共用。
struct WebAvatar: View {
    let profile: YYBarWebAccount.Profile
    var size: CGFloat = 18

    var body: some View {
        AsyncImage(url: profile.avatarUrl.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Text(profile.login.prefix(1).uppercased())
                .scaledFont(size: size * 0.5, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.15))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

// MARK: - 两张扑克牌图标

/// 两张叠着的扑克牌(后一张向左倾、前一张向右倾，前一张上有个方片)，代替 SF Symbol 用在 Popover 和侧边栏的 bar 入口。
/// 线条颜色跟着 foregroundStyle 走，和 SF Symbol 一样。
struct PlayingCardsIcon: View {
    var size: CGFloat = 13

    var body: some View {
        Canvas { ctx, canvas in
            let w = canvas.width * 0.56, h = canvas.height * 0.8, radius = canvas.width * 0.1
            let line = max(1, canvas.width * 0.085)
            func card(cx: CGFloat, cy: CGFloat, angle: Double) -> Path {
                Path(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerRadius: radius)
                    .applying(CGAffineTransform(rotationAngle: angle * .pi / 180)
                        .concatenating(CGAffineTransform(translationX: cx, y: cy)))
            }
            let back = card(cx: canvas.width * 0.38, cy: canvas.height * 0.5, angle: -14)
            let front = card(cx: canvas.width * 0.62, cy: canvas.height * 0.52, angle: 10)
            ctx.stroke(back, with: .foreground, lineWidth: line)
            // 先把前一张牌的位置(连同一圈空隙)擦掉，后一张牌的线就不会穿过来
            var erase = ctx
            erase.blendMode = .clear
            erase.fill(front, with: .color(.black))
            erase.stroke(front, with: .color(.black), lineWidth: line * 2.6)
            ctx.stroke(front, with: .foreground, lineWidth: line)
            // 方片
            let c = CGPoint(x: canvas.width * 0.62, y: canvas.height * 0.52), d = canvas.width * 0.12
            var pip = Path()
            pip.move(to: CGPoint(x: c.x, y: c.y - d * 1.3))
            pip.addLine(to: CGPoint(x: c.x + d, y: c.y))
            pip.addLine(to: CGPoint(x: c.x, y: c.y + d * 1.3))
            pip.addLine(to: CGPoint(x: c.x - d, y: c.y))
            pip.closeSubpath()
            ctx.fill(pip, with: .foreground)
        }
        .frame(width: size * 1.25, height: size)
    }
}

private extension Color {
    /// 像素画调色板用：0xRRGGBB。
    static func px(_ rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}
