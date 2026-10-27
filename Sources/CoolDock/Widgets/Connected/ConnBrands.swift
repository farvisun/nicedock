import SwiftUI

/// Services drawn by `ConnBrandMark`.
enum ConnBrand {
    case polar, stripe, dodo, shopify, plausible, simpleAnalytics, visitors, dataFast
    case dub, resend, github, supabase, x, tiktok, youtube, claude, codex, openai
    case cursor, copilot, gemini, perplexity, grok, zai, opencode, antigravity
}

/// Drawn brand marks (no bundled artwork). `icon` = rounded-square "app icon" variant used for the
/// large 44 pt marks; otherwise a round badge. Brand surfaces keep their own colours.
struct ConnBrandMark: View {
    @Environment(\.metrics) private var m
    var brand: ConnBrand
    var size: CGFloat = 18
    var icon = false

    var body: some View {
        let s = m.u(size)
        mark(s)
            .frame(width: s, height: s)
            .compositingGroup()
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityHidden(true)
    }

    private func squircle(_ s: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: s * 0.225, style: .continuous)
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    @ViewBuilder private func mark(_ s: CGFloat) -> some View {
        switch brand {
        case .polar:
            ZStack {
                Circle().fill(Color.black.opacity(0.1))
                Circle().strokeBorder(Color.white.opacity(0.42), lineWidth: max(s * 0.055, 0.8))
                ConnGlyph(d: ConnBrandPaths.polar, viewBox: ConnBrandPaths.unit100).fill(Color.white, style: FillStyle(eoFill: true))
            }
        case .stripe:
            ZStack {
                (icon ? AnyShape(squircle(s)) : AnyShape(Circle())).fill(Color(hex: "#635BFF"))
                Text(verbatim: "S").font(.system(size: s * 0.6, weight: .heavy, design: .rounded)).foregroundStyle(Color.white)
            }
        case .dodo:
            ZStack {
                Circle().fill(Color(hex: "#C7FA1E"))
                Circle().strokeBorder(Color(hex: "#DAF88E"), lineWidth: s / 18)
                ConnGlyph(d: ConnBrandPaths.dodo, viewBox: ConnBrandPaths.unit100)
                    .fill(Color(hex: "#0D0D0D"), style: FillStyle(eoFill: true))
            }
        case .shopify:
            ZStack {
                if icon {
                    // Shopify's own icon artwork has rounder corners than the system squircle.
                    RoundedRectangle(cornerRadius: s * 0.26, style: .continuous)
                        .fill(LinearGradient(colors: [Color.white, Color(hex: "#ECECEC")], startPoint: .top, endPoint: .bottom))
                } else {
                    Circle().fill(Color.white)
                }
                ConnShopifyBag()
            }
        case .plausible:
            ZStack {
                Circle().fill(LinearGradient(colors: [Color.white, Color(hex: "#ECECF1")], startPoint: .top, endPoint: .bottom))
                ConnPlausibleP()
                    .fill(LinearGradient(colors: [Color(hex: "#7E80EC"), Color(hex: "#5A4DDF"), Color(hex: "#5446DC")],
                                         startPoint: .topTrailing, endPoint: .bottomLeading))
                    .frame(width: s * 0.58, height: s * 0.78)
                    .overlay(ConnPlausibleSpark().stroke(Color.white, style: StrokeStyle(lineWidth: max(s * 0.035, 0.7), lineCap: .round, lineJoin: .round)))
                    .offset(x: s * 0.04)
            }
        case .simpleAnalytics, .visitors:
            ZStack(alignment: .topLeading) {
                Circle().fill(Color(hex: "#FDFDFD"))
                bar(s, x: 0.108, width: 0.211, top: 0.292, color: Color(hex: "#F2C3B3"))
                bar(s, x: 0.417, width: 0.166, top: 0.125, color: Color(hex: "#E26440"))
                bar(s, x: 0.708, width: 0.167, top: 0.403, color: Color(hex: "#F2C3B3"))
            }
        case .dataFast:
            BrandBadge(brand: .dataFast, size: size)
        case .dub:
            ConnDubShape().fill(Color.white, style: FillStyle(eoFill: true)).clipShape(Circle())
        case .resend:
            ZStack {
                (icon ? AnyShape(squircle(s)) : AnyShape(Circle())).fill(Color.black)
                ConnGlyph(d: ConnBrandPaths.resend)
                    .fill(LinearGradient(colors: [Color(white: 0.98), Color(white: 0.33)], startPoint: .top, endPoint: .bottom))
                    .frame(width: s * 0.511, height: s * 0.511)
            }
        case .github:
            BrandBadge(brand: .github, size: size)
        case .supabase:
            ZStack {
                (icon ? AnyShape(squircle(s)) : AnyShape(Circle())).fill(Color(hex: "#1C1C1C"))
                (icon ? AnyShape(squircle(s)) : AnyShape(Circle())).stroke(Color.white.opacity(0.12), lineWidth: 1)
                Image(systemName: "bolt.fill").font(.system(size: s * 0.5))
                    .foregroundStyle(LinearGradient(colors: [Color(hex: "#3ECF8E"), Color(hex: "#24935F")], startPoint: .top, endPoint: .bottom))
            }
        case .x:
            ZStack {
                Circle().fill(Color.black)
                ConnGlyph(d: ConnBrandPaths.x).fill(Color.white).frame(width: s * 0.568, height: s * 0.568)
            }
        case .tiktok:
            ZStack {
                Circle().fill(Color.white)
                ConnGlyph(d: ConnBrandPaths.tiktokCyan, viewBox: ConnBrandPaths.unit100).fill(Color(hex: "#2CC9D0"))
                ConnGlyph(d: ConnBrandPaths.tiktokRed, viewBox: ConnBrandPaths.unit100).fill(Color(hex: "#F1264B"))
                ConnGlyph(d: ConnBrandPaths.tiktokNote, viewBox: ConnBrandPaths.unit100).fill(Color.black)
            }
        case .youtube:
            ZStack {
                Circle().fill(Color(hex: "#FF2732"))
                ConnGlyph(d: ConnBrandPaths.youtube).fill(Color.white, style: FillStyle(eoFill: true))
                    .frame(width: s * 0.659, height: s * 0.659)
            }
        case .claude:
            ZStack {
                Circle().fill(Color(hex: "#D57554"))
                Circle().strokeBorder(Color(hex: "#E6AE9A"), lineWidth: s / 18)
                ConnGlyph(d: ConnBrandPaths.claude).fill(Color(hex: "#FCF2ED")).frame(width: s * 0.72, height: s * 0.72)
            }
        case .codex:
            BrandBadge(brand: .codex, size: size)
        case .openai:
            BrandBadge(brand: .openai, size: size)
        case .cursor:
            ZStack {
                Circle().fill(Color(hex: "#14120B"))
                Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: max(s * 0.04, 0.6))
                ConnGlyph(d: ConnBrandPaths.cursor).fill(Color(hex: "#EDECEC"), style: FillStyle(eoFill: true))
                    .frame(width: s * 0.56, height: s * 0.56)
            }
        case .copilot:
            ZStack {
                Circle().fill(Color.black)
                ConnGlyph(d: ConnBrandPaths.copilot).fill(Color.white, style: FillStyle(eoFill: true))
                    .frame(width: s * 0.62, height: s * 0.62)
            }
        case .gemini:
            ZStack {
                Circle().fill(Color.white)
                ConnGlyph(d: ConnBrandPaths.gemini)
                    .fill(LinearGradient(colors: [Color(hex: "#1C7DFF"), Color(hex: "#6C6BF5"), Color(hex: "#E8607A")],
                                         startPoint: .bottomLeading, endPoint: .topTrailing))
                    .frame(width: s * 0.64, height: s * 0.64)
            }
        case .perplexity:
            ZStack {
                Circle().fill(Color(hex: "#1F1F1D"))
                ConnGlyph(d: ConnBrandPaths.perplexity).fill(Color(hex: "#20B8CD"), style: FillStyle(eoFill: true))
                    .frame(width: s * 0.6, height: s * 0.6)
            }
        case .grok:
            ZStack {
                Circle().fill(Color.black)
                Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: max(s * 0.04, 0.6))
                ConnGrokMark().stroke(Color.white, style: StrokeStyle(lineWidth: max(s * 0.085, 1), lineCap: .round))
                    .frame(width: s * 0.5, height: s * 0.5)
            }
        case .zai:
            ZStack {
                Circle().fill(Color(hex: "#2D5BFF"))
                Text(verbatim: "Z").font(.system(size: s * 0.58, weight: .black, design: .rounded)).foregroundStyle(Color.white)
                    .offset(x: -s * 0.02)
                Circle().fill(Color.white).frame(width: s * 0.11, height: s * 0.11).offset(x: s * 0.21, y: s * 0.17)
            }
        case .opencode:
            ZStack {
                Circle().fill(Color(hex: "#0F0F0F"))
                ConnGlyph(d: ConnBrandPaths.opencode).fill(Color.white, style: FillStyle(eoFill: true))
                    .frame(width: s * 0.44, height: s * 0.44)
            }
        case .antigravity:
            ZStack {
                Circle().fill(Color.white)
                ConnArch().stroke(AngularGradient(colors: [Color(hex: "#4285F4"), Color(hex: "#34A853"), Color(hex: "#FBBC04"),
                                                           Color(hex: "#EA4335"), Color(hex: "#4285F4")], center: .center),
                                  style: StrokeStyle(lineWidth: s * 0.13, lineCap: .round))
                    .frame(width: s * 0.56, height: s * 0.5)
                    .offset(y: s * 0.03)
            }
        }
    }

    /// One Simple Analytics bar, in fractions of the mark (all bars end at 85 %).
    private func bar(_ s: CGFloat, x: CGFloat, width: CGFloat, top: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: s * 0.02, style: .continuous).fill(color)
            .frame(width: s * width, height: s * (0.847 - top))
            .offset(x: s * x, y: s * top)
    }
}

/// Glyph outlines for the drawn marks: Simple Icons (CC0) in 24-unit boxes (incl. Cursor, GitHub Copilot, Google Gemini,
/// Perplexity, OpenCode); the Polar globe, the Dodo badge,
/// the layered TikTok note and the Shopify bag are traced from the reference frames (0…100 units of the mark).
private enum ConnBrandPaths {
    static let unit100 = CGRect(x: 0, y: 0, width: 100, height: 100)
    static let x = "M14.234 10.162 22.977 0h-2.072l-7.591 8.824L7.251 0H.258l9.168 13.343L.258 24H2.33l8.016-9.318L16.749 24h6.993zm-2.837 3.299-.929-1.329L3.076 1.56h3.182l5.965 8.532.929 1.329 7.754 11.09h-3.182z"
    static let tiktokCyan = "M48.3 76.7 42.6 77.5 38.1 77.1 34.7 75.9 30.9 73.3 27.7 69.9 25.0 64.2 24.1 58.5 24.7 55.1 25.6 52.1 27.7 48.3 29.6 46.0 32.5 43.8 34.7 42.4 39.2 41.1 43.8 40.9 44.9 41.4 45.3 44.9 45.3 49.4 44.9 50.3 39.2 51.4 36.0 54.0 34.4 57.4 34.5 60.8 35.3 63.1 36.9 65.3 40.3 67.3 43.8 67.7 46.0 67.2 48.7 65.3 50.7 61.9 51.2 58.5 51.2 21.0 51.7 20.4 52.8 20.3 59.7 20.4 63.1 27.3 65.5 30.1 68.8 32.4 74.8 34.7 75.1 42.6 74.4 43.3 69.0 42.6 66.5 41.7 61.9 38.8 61.5 39.2 61.3 58.5 60.1 65.3 57.9 69.9 55.9 72.2 52.8 74.6Z"
    static let tiktokRed = "M49.4 79.2 43.8 79.5 40.3 79.0 34.7 76.3 32.4 74.5 30.1 72.1 27.5 67.6 26.4 61.9 26.5 58.5 28.3 52.8 31.2 48.6 33.5 46.6 39.2 43.4 43.8 42.7 47.2 43.3 47.6 51.7 47.2 52.4 41.5 53.5 39.4 55.1 37.1 58.5 36.9 61.9 37.8 65.3 39.2 67.1 41.8 68.8 46.0 69.4 48.3 69.0 50.7 67.6 52.8 64.2 53.3 61.9 53.3 23.3 54.0 22.2 55.1 21.9 61.9 22.4 63.1 23.9 65.2 29.0 67.0 31.2 71.0 34.2 77.6 36.9 77.5 44.9 75.6 45.3 69.9 44.0 64.2 40.8 63.7 42.6 63.5 63.1 62.0 68.8 60.1 72.2 56.8 75.6 55.1 76.8Z"
    static let tiktokNote = "M48.3 76.7 43.8 77.5 39.2 77.3 34.7 75.9 32.4 74.5 30.1 72.1 27.5 67.6 26.4 61.9 26.6 58.5 28.4 52.8 31.2 48.7 32.9 47.2 39.2 43.5 44.9 42.9 45.3 44.9 45.3 49.4 44.9 50.3 39.2 51.4 36.0 54.0 34.4 57.4 34.5 60.8 35.3 63.1 36.9 65.3 41.8 68.8 46.0 69.4 48.3 69.1 50.7 67.6 52.9 64.2 53.3 61.9 53.3 23.3 54.0 22.2 55.1 22.0 59.7 22.0 60.8 22.6 63.1 27.3 65.5 30.1 69.9 33.5 74.7 35.8 75.2 36.9 75.1 42.6 74.4 43.3 69.0 42.6 66.5 41.7 61.9 38.8 61.5 39.2 61.3 58.5 60.1 65.3 57.9 69.9 55.9 72.2 52.8 74.6Z"
    static let youtube = "M23.498 6.186a3.016 3.016 0 0 0-2.122-2.136C19.505 3.545 12 3.545 12 3.545s-7.505 0-9.377.505A3.017 3.017 0 0 0 .502 6.186C0 8.07 0 12 0 12s0 3.93.502 5.814a3.016 3.016 0 0 0 2.122 2.136c1.871.505 9.376.505 9.376.505s7.505 0 9.377-.505a3.015 3.015 0 0 0 2.122-2.136C24 15.93 24 12 24 12s0-3.93-.502-5.814zM9.545 15.568V8.432L15.818 12l-6.273 3.568z"
    static let resend = "M14.679 0c4.648 0 7.413 2.765 7.413 6.434s-2.765 6.434-7.413 6.434H12.33L24 24h-8.245l-8.88-8.44c-.636-.588-.93-1.273-.93-1.86 0-.831.587-1.565 1.713-1.883l4.574-1.224c1.737-.465 2.936-1.81 2.936-3.572 0-2.153-1.761-3.4-3.939-3.4H0V0z"
    static let claude = "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"
    static let cursor = "M11.503.131 1.891 5.678a.84.84 0 0 0-.42.726v11.188c0 .3.162.575.42.724l9.609 5.55a1 1 0 0 0 .998 0l9.61-5.55a.84.84 0 0 0 .42-.724V6.404a.84.84 0 0 0-.42-.726L12.497.131a1.01 1.01 0 0 0-.996 0M2.657 6.338h18.55c.263 0 .43.287.297.515L12.23 22.918c-.062.107-.229.064-.229-.06V12.335a.59.59 0 0 0-.295-.51l-9.11-5.257c-.109-.063-.064-.23.061-.23"
    static let copilot = "M23.922 16.997C23.061 18.492 18.063 22.02 12 22.02 5.937 22.02.939 18.492.078 16.997A.641.641 0 0 1 0 16.741v-2.869a.883.883 0 0 1 .053-.22c.372-.935 1.347-2.292 2.605-2.656.167-.429.414-1.055.644-1.517a10.098 10.098 0 0 1-.052-1.086c0-1.331.282-2.499 1.132-3.368.397-.406.89-.717 1.474-.952C7.255 2.937 9.248 1.98 11.978 1.98c2.731 0 4.767.957 6.166 2.093.584.235 1.077.546 1.474.952.85.869 1.132 2.037 1.132 3.368 0 .368-.014.733-.052 1.086.23.462.477 1.088.644 1.517 1.258.364 2.233 1.721 2.605 2.656a.841.841 0 0 1 .053.22v2.869a.641.641 0 0 1-.078.256Zm-11.75-5.992h-.344a4.359 4.359 0 0 1-.355.508c-.77.947-1.918 1.492-3.508 1.492-1.725 0-2.989-.359-3.782-1.259a2.137 2.137 0 0 1-.085-.104L4 11.746v6.585c1.435.779 4.514 2.179 8 2.179 3.486 0 6.565-1.4 8-2.179v-6.585l-.098-.104s-.033.045-.085.104c-.793.9-2.057 1.259-3.782 1.259-1.59 0-2.738-.545-3.508-1.492a4.359 4.359 0 0 1-.355-.508Zm2.328 3.25c.549 0 1 .451 1 1v2c0 .549-.451 1-1 1-.549 0-1-.451-1-1v-2c0-.549.451-1 1-1Zm-5 0c.549 0 1 .451 1 1v2c0 .549-.451 1-1 1-.549 0-1-.451-1-1v-2c0-.549.451-1 1-1Zm3.313-6.185c.136 1.057.403 1.913.878 2.497.442.544 1.134.938 2.344.938 1.573 0 2.292-.337 2.657-.751.384-.435.558-1.15.558-2.361 0-1.14-.243-1.847-.705-2.319-.477-.488-1.319-.862-2.824-1.025-1.487-.161-2.192.138-2.533.529-.269.307-.437.808-.438 1.578v.021c0 .265.021.562.063.893Zm-1.626 0c.042-.331.063-.628.063-.894v-.02c-.001-.77-.169-1.271-.438-1.578-.341-.391-1.046-.69-2.533-.529-1.505.163-2.347.537-2.824 1.025-.462.472-.705 1.179-.705 2.319 0 1.211.175 1.926.558 2.361.365.414 1.084.751 2.657.751 1.21 0 1.902-.394 2.344-.938.475-.584.742-1.44.878-2.497Z"
    static let gemini = "M11.04 19.32Q12 21.51 12 24q0-2.49.93-4.68.96-2.19 2.58-3.81t3.81-2.55Q21.51 12 24 12q-2.49 0-4.68-.93a12.3 12.3 0 0 1-3.81-2.58 12.3 12.3 0 0 1-2.58-3.81Q12 2.49 12 0q0 2.49-.96 4.68-.93 2.19-2.55 3.81a12.3 12.3 0 0 1-3.81 2.58Q2.49 12 0 12q2.49 0 4.68.96 2.19.93 3.81 2.55t2.55 3.81"
    static let perplexity = "M22.3977 7.0896h-2.3106V.0676l-7.5094 6.3542V.1577h-1.1554v6.1966L4.4904 0v7.0896H1.6023v10.3976h2.8882V24l6.932-6.3591v6.2005h1.1554v-6.0469l6.9318 6.1807v-6.4879h2.8882V7.0896zm-3.4657-4.531v4.531h-5.355l5.355-4.531zm-13.2862.0676 4.8691 4.4634H5.6458V2.6262zM2.7576 16.332V8.245h7.8476l-6.1149 6.1147v1.9723H2.7576zm2.8882 5.0404v-3.8852h.0001v-2.6488l5.7763-5.7764v7.0111l-5.7764 5.2993zm12.7086.0248-5.7766-5.1509V9.0618l5.7766 5.7766v6.5588zm2.8882-5.0652h-1.733v-1.9723L13.3948 8.245h7.8478v8.087z"
    static let opencode = "M22 24H2V0h20zM17 4.8H7v14.4h10z"
    static let polar = "M54.2 83.3 45.8 83.3 43.1 80.7 37.5 80.6 34.7 77.8 31.9 77.8 25.0 70.8 27.4 68.1 27.8 65.3 24.4 62.5 25.0 51.4 27.8 45.8 27.8 40.3 30.6 37.5 30.6 34.7 34.7 30.6 36.1 31.9 36.1 34.7 33.3 37.5 32.8 43.1 30.6 45.8 30.6 65.3 33.3 68.1 33.3 70.8 37.5 75.0 38.9 73.6 36.1 70.8 36.1 59.7 35.2 54.2 36.1 51.4 36.4 37.5 38.9 34.7 38.9 31.9 40.3 29.5 41.7 31.9 41.7 34.7 41.5 37.5 38.9 40.3 38.9 56.9 39.3 59.7 41.7 62.5 41.7 68.1 44.4 70.8 44.4 73.6 45.8 75.0 51.4 77.7 56.9 71.3 58.6 70.8 58.3 65.3 61.1 59.7 61.1 40.3 58.3 37.5 58.3 31.9 55.6 29.2 55.6 26.4 54.2 25.0 48.6 23.5 44.4 26.4 43.1 29.5 40.3 28.8 38.4 26.4 41.7 23.6 40.3 22.2 37.5 25.5 31.9 27.8 27.8 34.7 25.0 37.5 25.0 40.3 22.2 43.1 22.2 59.7 23.1 62.5 20.8 63.9 19.4 62.5 19.4 56.9 16.7 54.2 17.0 45.8 19.4 43.1 19.4 37.5 22.2 34.7 22.2 31.9 31.9 22.2 34.7 22.2 37.5 19.4 43.1 19.4 45.8 16.7 54.2 16.9 56.9 19.4 62.5 19.4 65.3 22.2 68.1 22.2 75.0 29.2 72.5 31.9 72.2 34.7 75.4 37.5 74.5 51.4 72.2 54.2 72.2 59.7 69.4 62.5 69.4 65.3 65.3 69.4 63.9 68.1 63.9 65.3 66.7 62.5 66.7 59.7 69.4 54.2 69.4 34.7 66.7 31.9 66.7 29.2 63.9 26.4 62.5 25.0 61.1 26.4 63.9 29.2 63.9 37.5 66.0 43.1 63.9 51.4 63.9 62.5 61.1 65.3 61.1 68.1 63.9 70.8 62.5 73.6 58.3 76.4 59.7 77.8 62.5 73.7 65.3 74.9 72.2 68.1 72.2 65.3 75.0 62.5 75.0 59.7 77.8 56.9 77.4 37.5 79.2 36.1 80.6 37.5 80.7 43.1 83.3 45.8 83.3 54.2 80.9 56.9 80.6 62.5 77.8 65.3 77.8 68.1 68.1 77.8 65.3 77.8 62.5 80.6 56.9 80.7ZM37.5 30.6 36.1 29.2 37.5 27.3 39.9 29.2ZM76.4 36.5 75.0 34.7 74.7 31.9 76.4 30.6 77.8 31.9 77.8 34.7ZM23.6 69.4 22.2 68.1 22.2 65.3 23.6 63.0 25.0 65.3 25.4 68.1Z"
    static let dodo = "M54.2 85.4 34.7 85.4 27.9 76.4 20.1 62.5 16.9 54.2 16.0 43.1 17.8 31.9 16.8 29.2 19.9 26.4 20.8 23.0 40.3 22.3 48.6 25.2 59.7 36.1 70.8 36.5 79.2 38.9 84.7 41.7 88.7 45.8 89.6 51.4 88.9 62.5 87.6 65.3 84.7 67.1 79.2 61.1 70.8 59.5 54.2 61.0 51.4 62.5 50.5 68.1 56.6 84.7ZM58.6 56.9 61.1 54.2 61.1 45.8 63.9 40.3 62.5 38.9 56.9 38.7 45.8 30.6 34.7 31.0 30.6 37.5 30.6 45.8 33.9 51.4 40.3 55.6 56.9 57.9ZM45.8 43.5 40.3 44.2 39.1 43.1 38.9 40.3 43.1 36.2 47.2 40.3Z"
    static let shopifyIconBag = "M66.5 88.2 61.9 88.4 43.8 85.0 39.2 79.0 34.7 76.4 29.0 75.4 16.5 75.2 15.7 74.4 17.2 60.8 18.1 57.4 19.3 42.6 20.3 38.1 20.6 32.4 22.2 29.6 27.8 28.1 31.2 26.7 32.9 21.0 36.4 14.2 40.8 9.7 43.8 7.9 49.4 7.9 51.7 9.7 55.1 10.3 58.5 13.1 60.8 17.1 64.2 17.0 65.3 17.5 71.0 22.5 75.6 22.5 77.3 23.3 85.0 79.0 85.1 82.4 84.7 83.6ZM34.7 25.6 38.1 24.9 40.9 23.3 43.4 16.5 47.9 10.8 47.2 10.4 45.0 10.8 42.6 11.9 40.2 14.2 36.5 19.9 35.4 22.2ZM46.3 22.2 49.4 21.4 51.7 19.9 51.1 14.2 50.6 13.7 49.4 13.8 48.3 14.9 45.5 18.8 44.3 22.2 44.9 22.6ZM57.1 18.8 57.9 17.6 56.7 15.3 55.1 13.7 54.0 13.5 54.6 18.8 55.1 19.3ZM44.4 73.3 47.2 71.4 49.6 67.6 50.4 63.1 49.6 57.4 47.1 54.0 39.6 48.3 38.7 47.2 38.6 44.9 41.5 42.0 49.4 42.2 51.9 34.7 49.4 33.2 44.9 33.3 40.3 34.3 38.1 35.5 33.1 40.3 31.9 42.6 31.2 46.0 31.0 49.4 32.0 52.8 39.4 59.7 40.9 61.9 41.0 63.1 40.1 65.3 38.1 66.8 36.9 66.9 33.5 66.1 30.1 64.2 28.7 68.8 29.0 70.7 33.5 73.6 40.3 74.3Z"
    static let shopifyIconSide = "M71.0 84.9 67.4 84.7 66.5 83.7 66.0 80.1 65.7 23.3 66.5 21.3 69.9 24.0 75.1 24.4 76.9 26.7 76.8 32.4 77.9 34.7 78.0 40.3 79.3 42.6 79.2 48.3 80.4 50.6 80.5 56.2 81.6 57.4 81.4 63.1 81.7 64.2 82.7 65.3 82.5 71.0 83.9 73.3 83.1 81.2 82.4 82.0Z"
    static let shopifyIconS = "M41.5 74.7 38.1 74.8 33.5 73.9 28.8 71.0 28.4 68.8 29.5 64.2 30.1 63.6 33.5 65.6 36.9 66.3 39.2 65.9 40.8 63.1 39.2 60.1 32.4 54.0 30.7 50.6 31.1 43.8 34.2 38.1 39.2 34.2 43.8 32.8 50.6 32.8 52.1 33.5 52.4 34.7 50.1 42.6 49.4 43.2 46.0 42.1 42.6 42.2 40.0 43.8 39.2 46.0 40.3 48.3 46.0 52.4 48.8 55.1 51.0 60.8 50.9 64.2 48.9 69.9 46.0 72.7Z"
}

/// Shopify's bag as drawn in its app icon (same artwork in the round mark): front with the handle loops cut out,
/// shaded side face and the soft white "S".
private struct ConnShopifyBag: View {
    var body: some View {
        ZStack {
            ConnGlyph(d: ConnBrandPaths.shopifyIconBag, viewBox: ConnBrandPaths.unit100)
                .fill(LinearGradient(stops: [.init(color: Color(hex: "#9AD626"), location: 0.1), .init(color: Color(hex: "#90CC28"), location: 0.3),
                                             .init(color: Color(hex: "#7DB42B"), location: 0.49), .init(color: Color(hex: "#6C9D38"), location: 0.72),
                                             .init(color: Color(hex: "#689640"), location: 0.86)], startPoint: .top, endPoint: .bottom),
                      style: FillStyle(eoFill: true))
            ConnGlyph(d: ConnBrandPaths.shopifyIconSide, viewBox: ConnBrandPaths.unit100)
                .fill(LinearGradient(stops: [.init(color: Color(hex: "#74A61B"), location: 0.2), .init(color: Color(hex: "#689719"), location: 0.33),
                                             .init(color: Color(hex: "#507915"), location: 0.58), .init(color: Color(hex: "#476F1B"), location: 0.78),
                                             .init(color: Color(hex: "#436A1C"), location: 0.9)], startPoint: .top, endPoint: .bottom))
            ConnGlyph(d: ConnBrandPaths.shopifyIconS, viewBox: ConnBrandPaths.unit100)
                .fill(LinearGradient(stops: [.init(color: .white, location: 0.45), .init(color: Color(hex: "#E0EBD1"), location: 0.68),
                                             .init(color: Color(hex: "#D5E3C2"), location: 0.8)], startPoint: .top, endPoint: .bottom))
        }
    }
}

/// Grok / xAI: a long stroke corner to corner and a shorter one crossing it, after the xAI wordmark's X.
private struct ConnGrokMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.08, y: r.maxY - r.height * 0.02))
        p.addLine(to: CGPoint(x: r.maxX - r.width * 0.02, y: r.minY + r.height * 0.02))
        p.move(to: CGPoint(x: r.minX + r.width * 0.12, y: r.minY + r.height * 0.18))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.5, y: r.minY + r.height * 0.56))
        return p
    }
}

/// Antigravity: an arch rising from both feet.
private struct ConnArch: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.maxY), control1: CGPoint(x: r.minX + r.width * 0.12, y: r.minY - r.height * 0.32),
                   control2: CGPoint(x: r.maxX - r.width * 0.12, y: r.minY - r.height * 0.32))
        return p
    }
}

/// Dub's "d": a disc with a round counter and a slot down to the counter's foot that frees the stem.
private struct ConnDubShape: Shape {
    func path(in r: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y) }
        var p = Path(ellipseIn: r)
        let radius: CGFloat = 0.247, slotLeft: CGFloat = 0.625, slotRight: CGFloat = 0.75, slotBottom: CGFloat = 0.75
        // Counter ∪ slot as one outline: down the slot's left edge, the long way round the counter, back up the slot.
        let half = asin((slotLeft - 0.5) / radius)  // angle of the slot edge from 12 o'clock
        p.move(to: pt(slotLeft, -0.01))
        let steps = 72
        for i in 0...steps {
            let a = -.pi / 2 + half - CGFloat(i) / CGFloat(steps) * (2 * .pi - 2 * (.pi / 2 - half))
            p.addLine(to: pt(0.5 + radius * cos(a), 0.5 + radius * sin(a)))
        }
        p.addLine(to: pt(slotLeft, slotBottom))
        p.addLine(to: pt(slotRight, slotBottom))
        p.addLine(to: pt(slotRight, -0.01))
        p.closeSubpath()
        return p
    }
}

/// Plausible's rounded "P" block.
private struct ConnPlausibleP: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.7),
                         cornerSize: CGSize(width: r.width * 0.34, height: r.width * 0.34), style: .continuous)
        p.addRoundedRect(in: CGRect(x: r.minX, y: r.minY + r.height * 0.3, width: r.width * 0.46, height: r.height * 0.7),
                         cornerSize: CGSize(width: r.width * 0.2, height: r.width * 0.2), style: .continuous)
        return p
    }
}

/// The white trend line across the Plausible "P".
private struct ConnPlausibleSpark: Shape {
    func path(in r: CGRect) -> Path {
        let pts: [(CGFloat, CGFloat)] = [(0, 0.538), (0.103, 0.474), (0.172, 0.449), (0.224, 0.481), (0.328, 0.481), (0.407, 0.397),
                                         (0.552, 0.263), (0.638, 0.301), (0.707, 0.308), (0.914, 0.212)]
        return Path.polyline(pts.map { CGPoint(x: r.minX + r.width * $0.0, y: r.minY + r.height * $0.1) })
    }
}

// MARK: - Range pill

/// Small dark chip ("7D", "TDY") overlapping the corner of a large brand icon.
struct ConnRangePill: View {
    @Environment(\.metrics) private var m
    var text: String

    var body: some View {
        Text(verbatim: text)
            .font(.dock(m.u(7), .bold))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, m.u(3))
            .frame(minWidth: m.u(12.75), minHeight: m.u(12.75))
            .background(Capsule().fill(Color.black.opacity(0.72)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.17), lineWidth: m.u(1)))
    }
}

/// Large 44 pt brand icon with an optional range pill at its bottom-leading corner.
struct ConnBigMark: View {
    @Environment(\.metrics) private var m
    @Environment(\.layoutDirection) private var direction
    var brand: ConnBrand
    var icon: Bool
    var pill: String?

    var body: some View {
        ConnBrandMark(brand: brand, size: 44, icon: icon)
            .overlay(alignment: .bottomLeading) {
                if let pill {
                    // Hangs just outside the icon's corner.
                    ConnRangePill(text: pill)
                        .offset(x: m.u(direction == .rightToLeft ? 2.25 : -2.25), y: m.u(1.75))
                }
            }
    }
}

// MARK: - SVG path data

/// Brand glyph from SVG path data (M L H V C S Q T A Z, absolute and relative), scaled from `viewBox`
/// into the shape's rect (see `ConnBrandPaths`).
struct ConnGlyph: Shape {
    var d: String
    var viewBox = CGRect(x: 0, y: 0, width: 24, height: 24)

    func path(in r: CGRect) -> Path {
        var base = Path()
        for sub in ConnSVG.subpaths(d) { base.addPath(sub) }
        let sx = r.width / viewBox.width, sy = r.height / viewBox.height
        return base.applying(CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: r.minX - viewBox.minX * sx, ty: r.minY - viewBox.minY * sy))
    }
}

enum ConnSVG {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [Path]] = [:]

    /// Parsed subpaths (split at each moveto), cached per path string.
    static func subpaths(_ d: String) -> [Path] {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[d] { return hit }
        let parsed = parse(d)
        cache[d] = parsed
        return parsed
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func parse(_ d: String) -> [Path] {
        var out: [Path] = []
        var path = Path()
        var scanner = ConnSVGScanner(Array(d.utf8))
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCtrl: CGPoint?, lastQuad: CGPoint?
        var cmd: UInt8 = 0
        func flush() {
            if !path.isEmpty { out.append(path) }
            path = Path()
        }
        while let c = scanner.command(after: cmd) {
            cmd = c
            let rel = c >= 97
            let base = rel ? cur : .zero
            func pt() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return CGPoint(x: base.x + x, y: base.y + y)
            }
            var ctrl: CGPoint?, quad: CGPoint?
            switch c | 32 {
            case UInt8(ascii: "m"):
                guard let p = pt() else { return out }
                flush()
                path.move(to: p)
                cur = p; start = p
                cmd = rel ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "l"):
                guard let p = pt() else { return out }
                path.addLine(to: p); cur = p
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return out }
                cur = CGPoint(x: base.x + x, y: cur.y); path.addLine(to: cur)
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return out }
                cur = CGPoint(x: cur.x, y: (rel ? cur.y : 0) + y); path.addLine(to: cur)
            case UInt8(ascii: "c"):
                guard let c1 = pt(), let c2 = pt(), let p = pt() else { return out }
                path.addCurve(to: p, control1: c1, control2: c2); cur = p; ctrl = c2
            case UInt8(ascii: "s"):
                guard let c2 = pt(), let p = pt() else { return out }
                let c1 = lastCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                path.addCurve(to: p, control1: c1, control2: c2); cur = p; ctrl = c2
            case UInt8(ascii: "q"):
                guard let q = pt(), let p = pt() else { return out }
                path.addQuadCurve(to: p, control: q); cur = p; quad = q
            case UInt8(ascii: "t"):
                guard let p = pt() else { return out }
                let q = lastQuad.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                path.addQuadCurve(to: p, control: q); cur = p; quad = q
            case UInt8(ascii: "a"):
                guard let rx = scanner.number(), let ry = scanner.number(), let rot = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(), let p = pt() else { return out }
                arc(&path, from: cur, to: p, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
                cur = p
            case UInt8(ascii: "z"):
                path.closeSubpath(); cur = start
            default:
                return out
            }
            lastCtrl = ctrl
            lastQuad = quad
        }
        flush()
        return out
    }

    /// SVG elliptical arc (endpoint form) as cubic Béziers.
    private static func arc(_ path: inout Path, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat,
                            large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180, cp = cos(phi), sp = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cp * dx + sp * dy, y1 = -sp * dx + cp * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var k = sqrt(max(0, num / den))
        if large == sweep { k = -k }
        let cxp = k * rx * y1 / ry, cyp = -k * ry * x1 / rx
        let cx = cp * cxp - sp * cyp + (p0.x + p1.x) / 2, cy = sp * cxp + cp * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let t1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var dt = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep && dt > 0 { dt -= 2 * .pi } else if sweep && dt < 0 { dt += 2 * .pi }
        let segments = max(1, Int(ceil(abs(dt) / (.pi / 2))))
        let step = dt / CGFloat(segments)
        let alpha = 4 / 3 * tan(step / 4)
        func point(_ t: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(t) * cp - ry * sin(t) * sp, y: cy + rx * cos(t) * sp + ry * sin(t) * cp)
        }
        func deriv(_ t: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(t) * cp - ry * cos(t) * sp, y: -rx * sin(t) * sp + ry * cos(t) * cp)
        }
        var t = t1
        for _ in 0..<segments {
            let a = point(t), b = point(t + step), da = deriv(t), db = deriv(t + step)
            path.addCurve(to: b, control1: CGPoint(x: a.x + alpha * da.x, y: a.y + alpha * da.y),
                          control2: CGPoint(x: b.x - alpha * db.x, y: b.y - alpha * db.y))
            t += step
        }
    }
}

/// Tokenizer for SVG path data (handles "-.5.5", exponents and packed arc flags).
private struct ConnSVGScanner {
    let s: [UInt8]
    var i = 0
    init(_ s: [UInt8]) { self.s = s }

    private mutating func skip() {
        while i < s.count, s[i] == 32 || s[i] == 44 || s[i] == 9 || s[i] == 10 || s[i] == 13 { i += 1 }
    }

    private static func isLetter(_ c: UInt8) -> Bool { (c | 32) >= 97 && (c | 32) <= 122 && (c | 32) != 101 }

    /// Next command letter, or the previous one repeated when more numbers follow.
    mutating func command(after previous: UInt8) -> UInt8? {
        skip()
        guard i < s.count else { return nil }
        if Self.isLetter(s[i]) {
            defer { i += 1 }
            return s[i]
        }
        return previous == 0 ? nil : previous
    }

    mutating func flag() -> Bool? {
        skip()
        guard i < s.count, s[i] == 48 || s[i] == 49 else { return nil }
        defer { i += 1 }
        return s[i] == 49
    }

    mutating func number() -> CGFloat? {
        skip()
        let begin = i
        if i < s.count, s[i] == 43 || s[i] == 45 { i += 1 }
        var dot = false
        while i < s.count {
            let c = s[i]
            if c >= 48 && c <= 57 {
                i += 1
            } else if c == 46 && !dot {
                dot = true; i += 1
            } else if (c == 101 || c == 69), i > begin {
                i += 1
                if i < s.count, s[i] == 43 || s[i] == 45 { i += 1 }
            } else {
                break
            }
        }
        guard i > begin, let v = Double(String(decoding: s[begin..<i], as: UTF8.self)) else { return nil }
        return CGFloat(v)
    }
}
