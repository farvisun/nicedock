import AppKit
import SwiftUI

/// Controls & utilities family (also hosts Bookmarks and Search Web).
enum UtilityWidgets {
    @MainActor @ViewBuilder
    static func view(_ w: WidgetInstance) -> some View {
        switch w.kind {
        case .audioControls: UtilAudioView(w: w)
        case .quickToggles: UtilTogglesView(w: w)
        case .clipboard: UtilClipboardTile(w: w)
        case .screenshots: UtilScreenshotsView(w: w)
        case .recentScreenshots: UtilRecentScreenshotsTile(w: w)
        case .voiceMemo: UtilVoiceMemoView(w: w)
        case .emoji: UtilEmojiView(w: w)
        case .colorPicker: UtilColorPickerView(w: w)
        case .converter: UtilConverterView(w: w)
        case .calculator: UtilCalculatorView(w: w)
        case .separator: UtilSeparator()
        case .space: UtilSpace(w: w)
        case .bookmarks: UtilBookmarksView(w: w)
        case .searchWeb: UtilSearchWebView(w: w)
        default: Tile(width: w.kind.spec.width) { Text(w.kind.spec.localizedTitle).dock(11) }
        }
    }

    @MainActor @ViewBuilder
    static func menu(_ w: WidgetInstance) -> some View {
        switch w.kind {
        case .audioControls:
            Button(L("Output Devices…")) { UtilAudioPanel.toggle(w) }
            Button(L("Sound Settings…")) { Open.url("x-apple.systempreferences:com.apple.Sound-Settings.extension") }
            Divider()
        case .clipboard:
            Button(L("Show History")) { UtilClipboardPanel.toggle(w) }
            Button(L("Clear History")) { UtilClipboardService.shared.clear() }
            Divider()
        case .screenshots, .recentScreenshots:
            Button(L("Recent Screenshots")) { UtilRecentScreenshotsPanel.toggle(w) }
            Button(L("Open Screenshots Folder")) { Open.path(UtilScreenshotService.folder.path) }
            Divider()
        case .voiceMemo:
            Button(L("Recordings…")) { UtilVoiceMemoPanel.toggle(w) }
            Button(L("Show in Finder")) { Open.path(UtilVoiceRecorder.directory.path) }
            Divider()
        case .colorPicker:
            Button(L("Pick a Color")) { UtilColorPicking.pick(w) }
            Button(L("Color Details")) { UtilColorPanel.toggle(w, hex: UtilColorPickerView.colors(w).first ?? "#FFFFFF") }
            Divider()
        case .emoji:
            Button(L("Emoji & Symbols")) { NSApp.orderFrontCharacterPalette(nil) }
            Divider()
        case .converter:
            Button(L("Swap Currencies")) { UtilConverterView.swap(w) }
            Divider()
        default:
            EmptyView()
        }
    }
}

// MARK: - Shared helpers

enum UtilEnv {
    /// True for the developer render harness: never prompt for permissions or touch user data there.
    static let rendering = CommandLine.arguments.contains("--render")
}

enum UtilPasteboard {
    static func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }
}

/// Programmatic pop-up menu (NSMenu) so the label can stay a plain SwiftUI view.
@MainActor
final class UtilMenu: NSObject {
    struct Item {
        var title: String
        var checked = false
        var action: () -> Void
    }
    private static var current: UtilMenu?
    private var actions: [() -> Void] = []

    static func show(_ items: [Item]) {
        let holder = UtilMenu()
        let menu = NSMenu()
        for (i, item) in items.enumerated() {
            let mi = NSMenuItem(title: item.title, action: #selector(fire(_:)), keyEquivalent: "")
            mi.target = holder
            mi.tag = i
            mi.state = item.checked ? .on : .off
            menu.addItem(mi)
        }
        holder.actions = items.map(\.action)
        current = holder
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func fire(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }
}

/// Text that turns into a focused text field on click. Idle tiles stay pure SwiftUI (cheaper than a
/// live NSTextField per tile, and renderable offscreen); editing ends on Return, Escape or focus loss.
struct UtilInlineField: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    @Binding var text: String
    @Binding var editing: Bool
    var placeholder: String
    var size: CGFloat
    var weight: Font.Weight = .medium
    var color: Color?
    var onSubmit: () -> Void = {}
    var onEnd: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            if editing {
                if text.isEmpty {
                    Text(verbatim: placeholder).dock(size, weight, p.tertiary).allowsHitTesting(false)
                }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.dock(m.u(size), weight))
                    .foregroundStyle(color ?? p.primary)
                    .lineLimit(1)
                    .focused($focused)
                    .onSubmit(onSubmit)
                    .onExitCommand {
                        focused = false
                        finish()
                    }
                    .onAppear {
                        UtilInlineField.makeDockKey()
                        DispatchQueue.main.async { focused = true }
                    }
                    .onChange(of: focused) { _, isFocused in if !isFocused { finish() } }
            } else {
                Text(verbatim: text.isEmpty ? placeholder : text)
                    .dock(size, weight, text.isEmpty ? p.tertiary : (color ?? p.primary))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { editing = true }
    }

    private func finish() {
        guard editing else { return }
        editing = false
        onEnd()
    }

    /// The dock is a non-activating panel; make the one under the pointer key so typing reaches the field.
    static func makeDockKey() {
        let mouse = NSEvent.mouseLocation
        NSApp.windows.first { $0.isVisible && $0.canBecomeKey && $0.frame.contains(mouse) }?.makeKey()
    }
}

/// Converts Persian / Arabic-Indic digits and separators to ASCII.
enum UtilDigits {
    static func normalize(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x06F0...0x06F9: out.unicodeScalars.append(UnicodeScalar(scalar.value - 0x06F0 + 48)!)
            case 0x0660...0x0669: out.unicodeScalars.append(UnicodeScalar(scalar.value - 0x0660 + 48)!)
            case 0x066B: out.append(".") // Arabic decimal separator
            case 0x066C: break // Arabic thousands separator
            case 0x060C: out.append(",") // Arabic comma
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Parses a user-typed amount; accepts `1,234.5`, `1.234,5`, `۱۲۳٫۵`.
    static func parseAmount(_ raw: String) -> Double? {
        var s = normalize(raw).filter { !$0.isWhitespace && $0 != "_" && $0 != "'" }
        if s.isEmpty { return nil }
        let commas = s.filter { $0 == "," }.count, dots = s.filter { $0 == "." }.count
        if commas > 0 && dots > 0 {
            // The later separator is the decimal one.
            if let lc = s.lastIndex(of: ","), let ld = s.lastIndex(of: "."), lc > ld {
                s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                s = s.replacingOccurrences(of: ",", with: "")
            }
        } else if commas == 1 {
            let after = s.split(separator: ",", omittingEmptySubsequences: false).last?.count ?? 0
            s = after == 3 ? s.replacingOccurrences(of: ",", with: "") : s.replacingOccurrences(of: ",", with: ".")
        } else if commas > 1 {
            s = s.replacingOccurrences(of: ",", with: "")
        }
        return Double(s)
    }
}

// MARK: - Separator & space

struct UtilSeparator: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var body: some View {
        Capsule()
            .fill(p.tertiary)
            .frame(width: m.u(1), height: m.u(34))
            .frame(width: m.u(9), height: m.tileHeight)
            .contentShape(Rectangle())
    }
}

struct UtilSpace: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    var body: some View {
        Color.clear
            .frame(width: m.u(CGFloat(min(200, max(4, w.double("width", 24))))), height: m.tileHeight)
            .contentShape(Rectangle())
    }
}

// MARK: - Emoji

struct UtilEmojiView: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    @State private var copied: Int?

    private var emoji: [String] {
        Array(w.string("emoji").filter { !$0.isWhitespace && $0 != "," }.prefix(9)).map(String.init)
    }

    var body: some View {
        let items = emoji
        Tile(width: w.kind.spec.width) {
            VStack(spacing: 0) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<5, id: \.self) { col in
                            cell(row * 5 + col, items)
                        }
                    }
                }
            }
            .environment(\.layoutDirection, .leftToRight)
        }
    }

    @ViewBuilder private func cell(_ i: Int, _ items: [String]) -> some View {
        Group {
            if i == min(items.count, 9) {
                Button { NSApp.orderFrontCharacterPalette(nil) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: m.u(15), weight: .medium))
                        .foregroundStyle(p.secondary)
                        .frame(width: m.u(28), height: m.u(28))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .help(L("Emoji & Symbols"))
            } else if i < items.count {
                Button { copy(i, items[i]) } label: {
                    ZStack {
                        if copied == i {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: m.u(17), weight: .semibold))
                                .foregroundStyle(p.accent(.cdGreen))
                                .transition(.scale.combined(with: .opacity))
                        } else {
                            Text(verbatim: items[i]).font(.system(size: m.u(16)))
                        }
                    }
                    .frame(width: m.u(28), height: m.u(28))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
            } else {
                Color.clear.frame(width: m.u(28), height: m.u(28))
            }
        }
    }

    private func copy(_ i: Int, _ s: String) {
        UtilPasteboard.copy(s)
        withAnimation(.easeOut(duration: 0.15)) { copied = i }
        Task {
            try? await Task.sleep(for: .seconds(0.9))
            withAnimation(.easeOut(duration: 0.2)) { if copied == i { copied = nil } }
        }
    }
}

// MARK: - Color picker

struct UtilColorPickerView: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    @State private var copied: Int?

    static let fallback = ["#EE5450", "#3499DC", "#FAC716"]

    static func colors(_ w: WidgetInstance) -> [String] {
        let list = w.string("colors").split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == " " })
            .map { $0.hasPrefix("#") ? String($0) : "#" + $0 }
            .filter { $0.count == 7 || $0.count == 9 }
        return Array((list.isEmpty ? fallback : list + fallback.filter { !list.contains($0) }).prefix(3))
    }

    var body: some View {
        let colors = Self.colors(w)
        Tile(width: w.kind.spec.width) {
            VStack(spacing: m.u(3.5)) {
                HStack(spacing: m.u(3.5)) {
                    swatch(0, colors)
                    swatch(1, colors)
                }
                HStack(spacing: m.u(3.5)) {
                    swatch(2, colors)
                    Button { UtilColorPicking.pick(w) } label: {
                        Image(systemName: "eyedropper")
                            .font(.system(size: m.u(10.5), weight: .semibold))
                            .foregroundStyle(p.secondary)
                            .frame(width: m.u(22), height: m.u(22))
                            .background(RoundedRectangle(cornerRadius: m.u(5), style: .continuous).fill(p.control))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .help(L("Pick a color from the screen"))
                }
            }
            .environment(\.layoutDirection, .leftToRight)
        }
    }

    private func swatch(_ i: Int, _ colors: [String]) -> some View {
        let hex = colors.indices.contains(i) ? colors[i] : "#808080"
        return Button {
            if NSEvent.modifierFlags.contains(.option) {
                UtilColorPanel.toggle(w, hex: hex)
            } else {
                UtilPasteboard.copy(hex)
                withAnimation(.easeOut(duration: 0.15)) { copied = i }
                Task {
                    try? await Task.sleep(for: .seconds(0.9))
                    withAnimation { if copied == i { copied = nil } }
                }
            }
        } label: {
            RoundedRectangle(cornerRadius: m.u(5), style: .continuous)
                .fill(Color(hex: hex))
                .frame(width: m.u(22), height: m.u(22))
                .overlay {
                    if copied == i {
                        Image(systemName: "checkmark")
                            .font(.system(size: m.u(10), weight: .heavy))
                            .foregroundStyle(UtilColorMath.isLight(hex) ? Color.black.opacity(0.7) : Color.white)
                    }
                }
        }
        .buttonStyle(PressableStyle())
        .help(hex + " — " + L("Click to copy, ⌥-click for details"))
    }
}

@MainActor
enum UtilColorPicking {
    private static var sampler: NSColorSampler?

    static func pick(_ w: WidgetInstance) {
        let s = NSColorSampler()
        sampler = s
        s.show { color in
            MainActor.assumeIsolated {
                sampler = nil
                guard let color, let srgb = color.usingColorSpace(.sRGB) else { return }
                let hex = String(format: "#%02X%02X%02X", Int((srgb.redComponent * 255).rounded()),
                                 Int((srgb.greenComponent * 255).rounded()), Int((srgb.blueComponent * 255).rounded()))
                let current = AppStore.shared.widget(w.id).map(UtilColorPickerView.colors) ?? UtilColorPickerView.colors(w)
                let recents = Array(([hex] + current.filter { $0.uppercased() != hex }).prefix(3))
                AppStore.shared.updateWidget(w.id) { $0.config["colors"] = recents.joined(separator: "\n") }
                UtilPasteboard.copy(hex)
                UtilColorPanel.show(w, hex: hex)
            }
        }
    }
}

enum UtilColorMath {
    static func rgb(_ hex: String) -> (r: Int, g: Int, b: Int) {
        let ns = NSColor(Color(hex: hex)).usingColorSpace(.sRGB) ?? .black
        return (Int((ns.redComponent * 255).rounded()), Int((ns.greenComponent * 255).rounded()), Int((ns.blueComponent * 255).rounded()))
    }

    static func hsl(_ hex: String) -> (h: Int, s: Int, l: Int) {
        let c = rgb(hex)
        let r = Double(c.r) / 255, g = Double(c.g) / 255, b = Double(c.b) / 255
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        var h = 0.0, s = 0.0
        if mx != mn {
            let d = mx - mn
            s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
            switch mx {
            case r: h = (g - b) / d + (g < b ? 6 : 0)
            case g: h = (b - r) / d + 2
            default: h = (r - g) / d + 4
            }
            h *= 60
        }
        return (Int(h.rounded()) % 360, Int((s * 100).rounded()), Int((l * 100).rounded()))
    }

    static func isLight(_ hex: String) -> Bool {
        let c = rgb(hex)
        return (0.299 * Double(c.r) + 0.587 * Double(c.g) + 0.114 * Double(c.b)) / 255 > 0.62
    }
}

@MainActor
enum UtilColorPanel {
    static func toggle(_ w: WidgetInstance, hex: String) {
        Panels.shared.toggle(w.id) { UtilColorPanelView(w: w, hex: hex) }
    }
    static func show(_ w: WidgetInstance, hex: String) {
        Panels.shared.show(w.id) { UtilColorPanelView(w: w, hex: hex) }
    }
}

private struct UtilColorPanelView: View {
    let w: WidgetInstance
    @State var hex: String
    @Environment(\.palette) private var p
    @State private var copied: String?

    var body: some View {
        let c = UtilColorMath.rgb(hex), h = UtilColorMath.hsl(hex)
        let formats: [(String, String)] = [
            (L("HEX"), hex.uppercased()),
            (L("RGB"), "rgb(\(c.r), \(c.g), \(c.b))"),
            (L("HSL"), "hsl(\(h.h), \(h.s)%, \(h.l)%)"),
            (L("SwiftUI"), String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", Double(c.r) / 255, Double(c.g) / 255, Double(c.b) / 255))
        ]
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: L("Color Picker")) {
                Button { Panels.shared.close(); UtilColorPicking.pick(w) } label: {
                    Label(L("Pick"), systemImage: "eyedropper").font(.dock(12, .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.accent(.cdBlue))
            }
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(hex: hex))
                    .frame(width: 64, height: 64)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.tileStroke, lineWidth: 1))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(UtilColorPickerView.colors(AppStore.shared.widget(w.id) ?? w), id: \.self) { other in
                        Button { hex = other } label: {
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 4).fill(Color(hex: other)).frame(width: 14, height: 14)
                                Text(verbatim: other.uppercased()).font(.dock(11, .medium, mono: true))
                                    .foregroundStyle(other == hex ? p.primary : p.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            VStack(spacing: 6) {
                ForEach(formats, id: \.0) { label, value in
                    HStack(spacing: 8) {
                        Text(label).font(.dock(11, .semibold)).foregroundStyle(p.secondary).frame(width: 52, alignment: .leading)
                        Text(verbatim: value).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(p.primary)
                            .lineLimit(1).minimumScaleFactor(0.7).textSelection(.enabled)
                            .environment(\.layoutDirection, .leftToRight)
                        Spacer(minLength: 8)
                        Button {
                            UtilPasteboard.copy(value)
                            copied = value
                        } label: {
                            Image(systemName: copied == value ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(copied == value ? p.accent(.cdGreen) : p.secondary)
                                .frame(width: 24, height: 22)
                                .background(RoundedRectangle(cornerRadius: 6).fill(p.control))
                        }
                        .buttonStyle(PressableStyle())
                        .help(L("Copy"))
                    }
                }
            }
        }
        .frame(width: 300)
    }
}

// MARK: - Search web

struct UtilSearchWebView: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    @State private var query = ""
    @State private var editing = false

    static func url(engine: String, query: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let q = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        let base: String
        switch engine {
        case "duckduckgo": base = "https://duckduckgo.com/?q="
        case "bing": base = "https://www.bing.com/search?q="
        case "perplexity": base = "https://www.perplexity.ai/search?q="
        case "chatgpt": base = "https://chatgpt.com/?q="
        case "claude": base = "https://claude.ai/new?q="
        case "kagi": base = "https://kagi.com/search?q="
        default: base = "https://www.google.com/search?q="
        }
        return URL(string: base + q)
    }

    var body: some View {
        Tile(width: w.kind.spec.width, padding: EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)) {
            HStack(spacing: m.u(8)) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: m.u(13.5), weight: .semibold))
                    .foregroundStyle(p.secondary)
                UtilInlineField(text: $query, editing: $editing, placeholder: L("Search web…"), size: 14.5, weight: .bold,
                                onSubmit: submit, onEnd: { if query.trimmingCharacters(in: .whitespaces).isEmpty { query = "" } })
                Button(action: submit) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: m.u(9.5), weight: .heavy))
                        .foregroundStyle(p.primary)
                        .flipsForRTL()
                        .frame(width: m.u(18), height: m.u(18))
                        .background(Circle().fill(p.primary.opacity(0.28)))
                        .contentShape(Circle())
                }
                .buttonStyle(PressableStyle())
                .help(L("Search"))
            }
        }
        .onTapGesture { editing = true }
    }

    private func submit() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let url = Self.url(engine: w.string("engine", "google"), query: q) else { return }
        NSWorkspace.shared.open(url)
        query = ""
        editing = false
    }
}
