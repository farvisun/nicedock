import AppKit
import SwiftUI

// MARK: - Exchange rates

struct UtilFXRate: Codable {
    let rate: Double
    let fetched: Date
}

/// Currency rates: Frankfurter (ECB) first, open.er-api.com for currencies the ECB doesn't publish,
/// Coinbase for BTC. Cached per pair for 12 hours (memory + DiskCache).
@MainActor
enum UtilFX {
    private static var memory: [String: UtilFXRate] = [:]
    private static let ttl: TimeInterval = 12 * 3600

    static func key(_ from: String, _ to: String) -> String { "fx-\(from)-\(to)" }

    /// Fixed rate for `--scene reference` renders: served from memory, so no disk cache or network is touched.
    static func seedReference(_ from: String, _ to: String, rate: Double) {
        guard ReferenceScene.isActive else { return }
        memory[key(from, to)] = UtilFXRate(rate: rate, fetched: Date())
    }

    /// Last known rate, even if stale (for instant display).
    static func cached(_ from: String, _ to: String) -> Double? {
        if from == to { return 1 }
        let k = key(from, to)
        if let m = memory[k] { return m.rate }
        if let d = DiskCache.load(UtilFXRate.self, k) { memory[k] = d; return d.rate }
        return nil
    }

    static func rate(_ from: String, _ to: String) async throws -> Double {
        if from == to { return 1 }
        let k = key(from, to)
        let known = memory[k] ?? DiskCache.load(UtilFXRate.self, k)
        if let known, Date().timeIntervalSince(known.fetched) < ttl { memory[k] = known; return known.rate }
        do {
            let r = try await fetch(from, to)
            let value = UtilFXRate(rate: r, fetched: Date())
            memory[k] = value
            DiskCache.save(value, k)
            return r
        } catch {
            if let known { return known.rate }
            throw error
        }
    }

    private static func fetch(_ from: String, _ to: String) async throws -> Double {
        if ReferenceScene.isActive { throw URLError(.notConnectedToInternet) }
        if from == "BTC" || to == "BTC" {
            let base = from == "BTC" ? from : to
            let other = from == "BTC" ? to : from
            guard let url = URL(string: "https://api.coinbase.com/v2/exchange-rates?currency=\(base)"),
                  let json = try await Net.json(url) as? [String: Any],
                  let rates = (json["data"] as? [String: Any])?["rates"] as? [String: Any],
                  let raw = rates[other] as? String, let r = Double(raw), r > 0 else { throw URLError(.cannotParseResponse) }
            return from == "BTC" ? r : 1 / r
        }
        if let url = URL(string: "https://api.frankfurter.app/latest?from=\(from)&to=\(to)"),
           let json = try? await Net.json(url) as? [String: Any],
           let r = (json["rates"] as? [String: Any])?[to] as? Double {
            return r
        }
        guard let url = URL(string: "https://open.er-api.com/v6/latest/\(from)"),
              let json = try await Net.json(url) as? [String: Any],
              let r = (json["rates"] as? [String: Any])?[to] as? Double else { throw URLError(.cannotParseResponse) }
        return r
    }
}

// MARK: - Converter

struct UtilConverterView: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    @State private var amountText = ""
    @State private var rate: Double?
    @State private var failed = false
    @State private var editing = false

    init(w: WidgetInstance) {
        self.w = w
        _amountText = State(initialValue: Fmt.digits(w.string("amount", "500")))
    }

    private var from: String { w.string("from", "USD") }
    private var to: String { w.string("to", "EUR") }

    static func swap(_ w: WidgetInstance) {
        let f = w.string("from", "USD"), t = w.string("to", "EUR")
        AppStore.shared.updateWidget(w.id) {
            $0.config["from"] = t
            $0.config["to"] = f
        }
    }

    var body: some View {
        Tile(width: w.kind.spec.width, padding: EdgeInsets(top: 0, leading: 11, bottom: 0, trailing: 6.5)) {
            HStack(spacing: m.u(6)) {
                VStack(alignment: .leading, spacing: m.u(0.5)) {
                    Group {
                        if ReferenceScene.isActive {
                            // The reference frame was captured mid-edit: the amount followed by the caret.
                            // Sub-pixel placement of the frame (transforms keep half pixels, `.offset` snaps).
                            HStack(spacing: m.u(-1.5)) {
                                Text(verbatim: amountText).dock(13, .semibold, p.secondary, mono: true)
                                    .transformEffect(CGAffineTransform(translationX: 0, y: m.u(-0.25)))
                                RoundedRectangle(cornerRadius: m.u(0.875)).fill(p.primary).frame(width: m.u(1.75), height: m.u(16))
                                    .transformEffect(CGAffineTransform(translationX: m.u(0.25), y: 0))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            // SF Pro Rounded 13 semibold with tabular digits, as the reference frame's amount.
                            UtilInlineField(text: $amountText, editing: $editing, placeholder: Fmt.digits("0"), size: 13, weight: .semibold,
                                            mono: true, color: p.secondary, onSubmit: { editing = false }, onEnd: save)
                        }
                    }
                    .frame(height: m.u(17))
                    Text(verbatim: result)
                        .dock(28, .bold, mono: true)
                        .minimumScaleFactor(0.4)
                        .frame(height: m.u(30))
                        .help(rateHelp)
                }
                .offset(y: m.u(-1.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: m.u(2.5)) {
                    currencyCapsule(from) { code in AppStore.shared.updateWidget(w.id) { $0.config["from"] = code } }
                    Button { Self.swap(w) } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: m.u(8), weight: .semibold))
                            .transformEffect(CGAffineTransform(translationX: 0, y: m.u(0.25)))
                            .foregroundStyle(p.tertiary.opacity(0.75))
                            .frame(width: m.u(30), height: m.u(13))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .help(L("Swap Currencies"))
                    currencyCapsule(to) { code in AppStore.shared.updateWidget(w.id) { $0.config["to"] = code } }
                }
            }
        }
        .task(id: from + to) { await load() }
        .onWidgetRefresh(w.id) { Task { await load() } }
    }

    private var amount: Double { UtilDigits.parseAmount(amountText) ?? 0 }

    /// Live state, else the last cached rate for the pair (instant display after launch).
    private var currentRate: Double? { rate ?? UtilFX.cached(from, to) }

    private var result: String {
        guard let rate = currentRate else { return failed ? "—" : "…" }
        let v = amount * rate
        // The reference frame shows the amount in a euro locale ("436,03").
        if ReferenceScene.isActive { return v.formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "de_DE"))) }
        return Fmt.number(v, decimals: abs(v) >= 100_000 ? 0 : 2)
    }

    private var rateHelp: String {
        guard let rate = currentRate else { return failed ? L("Exchange rate unavailable") : "" }
        return Fmt.digits("1 \(from) = ") + Fmt.number(rate, decimals: rate < 0.01 ? 6 : 4) + " \(to)"
    }

    private func load() async {
        failed = false
        rate = UtilFX.cached(from, to)
        do {
            rate = try await UtilFX.rate(from, to)
        } catch {
            if !Task.isCancelled && rate == nil { failed = true }
        }
    }

    private func save() {
        guard let v = UtilDigits.parseAmount(amountText) else { return }
        let normalized = v == v.rounded() ? String(Int(v)) : String(v)
        guard normalized != w.string("amount", "500") else { return }
        AppStore.shared.updateWidget(w.id) { $0.config["amount"] = normalized }
    }

    private func currencyCapsule(_ code: String, pick: @escaping (String) -> Void) -> some View {
        Button {
            UtilMenu.show(WidgetCatalog.currencyChoices.map { opt in
                UtilMenu.Item(title: opt.title, checked: opt.value == code) { pick(opt.value) }
            })
        } label: {
            Text(verbatim: code)
                .dock(8.8, .bold)
                .offset(y: m.u(-0.5))
                .frame(width: m.u(39.75), height: m.u(16))
                .background(Capsule().fill(p.primary.opacity(0.07)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Calculator

struct UtilCalculatorView: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    @State private var expression = ""
    @State private var copied = false
    @State private var editing = false

    var body: some View {
        let value = UtilCalc.evaluate(expression)
        Tile(width: w.kind.spec.width, padding: EdgeInsets(top: 0, leading: 11, bottom: 0, trailing: 10)) {
            VStack(alignment: .leading, spacing: m.u(2)) {
                UtilInlineField(text: $expression, editing: $editing, placeholder: Fmt.digits("12 × (3 + 4)"), size: 14, weight: .medium,
                                color: p.secondary, onSubmit: { copy(UtilCalc.evaluate(expression)) })
                    .frame(height: m.u(17))
                HStack(spacing: m.u(6)) {
                    Text(verbatim: value.map(UtilCalc.display) ?? (expression.isEmpty ? Fmt.digits("0") : "—"))
                        .dock(28, .bold, value == nil ? p.tertiary : p.primary, mono: true)
                        .minimumScaleFactor(0.4)
                    if copied {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: m.u(14), weight: .semibold))
                            .foregroundStyle(p.accent(.cdGreen))
                            .transition(.scale.combined(with: .opacity))
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: m.u(30))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.layoutDirection, .leftToRight) // math reads left-to-right in every language
        }
        .onTapGesture { editing = true }
        .help(L("Type math and press Return to copy the result"))
    }

    private func copy(_ value: Double?) {
        guard let value else { return }
        UtilPasteboard.copy(UtilCalc.plain(value))
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation { copied = false }
        }
    }
}

/// Small, safe recursive-descent evaluator:
/// `+ − × ÷ * / ^ %` (postfix percent or modulo), parentheses, decimals, implicit multiplication,
/// `√`/`sqrt`, `π`/`pi`, `e`; Persian/Arabic digits are normalised first.
enum UtilCalc {
    private struct Failure: Error {}

    private struct Parser {
        let chars: [Character]
        var i = 0

        init(_ s: String) { chars = Array(s) }

        mutating func skip() { while i < chars.count, chars[i] == " " { i += 1 } }
        mutating func peek() -> Character? { skip(); return i < chars.count ? chars[i] : nil }
        var atEnd: Bool { mutating get { peek() == nil } }

        mutating func expression() throws -> Double {
            var lhs = try term().value
            while let c = peek(), c == "+" || c == "-" {
                i += 1
                let rhs = try term()
                let r = rhs.percent ? lhs * rhs.value : rhs.value
                lhs = c == "+" ? lhs + r : lhs - r
            }
            return lhs
        }

        mutating func term() throws -> (value: Double, percent: Bool) {
            var lhs = try unary()
            while let c = peek() {
                if c == "*" || c == "/" {
                    i += 1
                    let rhs = try unary().value
                    if c == "/" && rhs == 0 { throw Failure() }
                    lhs = (c == "*" ? lhs.value * rhs : lhs.value / rhs, false)
                } else if c == "%" {
                    // Modulo when another operand follows; otherwise postfix percent.
                    let save = i
                    i += 1
                    if let n = peek(), n.isNumber || n == "(" || n == "." || n == "√" || n.isLetter {
                        let rhs = try unary().value
                        if rhs == 0 { throw Failure() }
                        lhs = (lhs.value.truncatingRemainder(dividingBy: rhs), false)
                    } else {
                        i = save + 1
                        lhs = (lhs.value / 100, true)
                    }
                } else if c == "(" || c == "√" || c == "π" || c.isLetter {
                    let rhs = try unary().value // implicit multiplication: 2(3+4), 2π
                    lhs = (lhs.value * rhs, false)
                } else {
                    break
                }
            }
            return lhs
        }

        mutating func unary() throws -> (value: Double, percent: Bool) {
            if let c = peek(), c == "-" || c == "+" {
                i += 1
                let v = try unary()
                return (c == "-" ? -v.value : v.value, v.percent)
            }
            return try power()
        }

        mutating func power() throws -> (value: Double, percent: Bool) {
            let base = try primary()
            if peek() == "^" {
                i += 1
                let exp = try unary().value
                let v = Foundation.pow(base, exp)
                guard v.isFinite else { throw Failure() }
                return (v, false)
            }
            return (base, false)
        }

        mutating func primary() throws -> Double {
            guard let c = peek() else { throw Failure() }
            if c == "(" {
                i += 1
                let v = try expression()
                guard peek() == ")" else { throw Failure() }
                i += 1
                return v
            }
            if c == "√" {
                i += 1
                let v = try power().value
                guard v >= 0 else { throw Failure() }
                return v.squareRoot()
            }
            if c == "π" { i += 1; return .pi }
            if c.isLetter {
                var name = ""
                while i < chars.count, chars[i].isLetter { name.append(chars[i]); i += 1 }
                switch name.lowercased() {
                case "pi": return .pi
                case "e": return M_E
                case "sqrt":
                    let v = try primary()
                    guard v >= 0 else { throw Failure() }
                    return v.squareRoot()
                default: throw Failure()
                }
            }
            var digits = ""
            while i < chars.count, chars[i].isASCII, chars[i].isNumber || chars[i] == "." {
                digits.append(chars[i])
                i += 1
            }
            guard let v = Double(digits) else { throw Failure() }
            return v
        }
    }

    static func normalize(_ s: String) -> String {
        var t = UtilDigits.normalize(s)
        let map: [Character: String] = ["×": "*", "x": "*", "X": "*", "·": "*", "÷": "/", ":": "/", "−": "-", "–": "-", "—": "-", "٪": "%", "＋": "+"]
        t = String(t.flatMap { map[$0] ?? String($0) })
        // "1,234" → grouping; "3,5" → decimal comma.
        var out = ""
        let chars = Array(t)
        for (idx, ch) in chars.enumerated() {
            guard ch == "," else { out.append(ch); continue }
            var run = 0
            var j = idx + 1
            while j < chars.count, chars[j].isNumber { run += 1; j += 1 }
            out.append(run == 3 ? "" : ".")
        }
        return out
    }

    static func evaluate(_ s: String) -> Double? {
        let text = normalize(s).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        var parser = Parser(text)
        guard let v = try? parser.expression(), parser.atEnd, v.isFinite else { return nil }
        return v
    }

    nonisolated(unsafe) private static var displayFormatter: NumberFormatter?
    nonisolated(unsafe) private static var displayLocale: Locale?

    /// Localised, grouped result (Persian digits when enabled).
    static func display(_ v: Double) -> String {
        if displayFormatter == nil || displayLocale != Fmt.locale {
            let f = NumberFormatter()
            f.locale = Fmt.locale
            f.numberStyle = .decimal
            f.maximumFractionDigits = 8
            f.usesSignificantDigits = false
            displayFormatter = f
            displayLocale = Fmt.locale
        }
        if abs(v) >= 1e15 || (abs(v) < 1e-8 && v != 0) { return Fmt.digits(String(format: "%.6g", v)) }
        return displayFormatter?.string(from: NSNumber(value: v)) ?? Fmt.digits("\(v)")
    }

    /// ASCII result for the pasteboard.
    static func plain(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        var s = String(format: "%.10f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
