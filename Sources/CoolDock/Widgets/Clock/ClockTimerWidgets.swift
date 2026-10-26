import SwiftUI

// MARK: - Shared pieces

/// Accent bases sampled from the references (passed through `p.accent` for Monochrome).
enum ClockTint {
    static let timer = Color(red: 255 / 255, green: 147 / 255, blue: 46 / 255)
    static let stopwatch = Color(red: 0, green: 122 / 255, blue: 255 / 255)
    static let focus = Color(red: 242 / 255, green: 88 / 255, blue: 98 / 255)
    static let rest = Color(red: 48 / 255, green: 200 / 255, blue: 98 / 255)
    static let progress = Color(red: 0, green: 122 / 255, blue: 255 / 255)
    static let water = Color(red: 68 / 255, green: 188 / 255, blue: 233 / 255)
}

/// Inner rounded rectangle with a track and a progress stroke that starts at the trailing middle
/// and runs clockwise (timer, pomodoro).
private struct ClockProgressFrame: View {
    var progress: Double
    var color: Color
    var gradient = false
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: m.u(6), style: .continuous)
        let line = m.u(2)
        let style: AnyShapeStyle = gradient
            ? AnyShapeStyle(LinearGradient(colors: [color.clockLighter, color], startPoint: .top, endPoint: .bottom))
            : AnyShapeStyle(color)
        ZStack {
            shape.stroke(p.track, lineWidth: line)
            if progress > 0.001 {
                shape.trim(from: 0, to: min(1, progress))
                    .stroke(style, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
            }
        }
        .padding(m.u(6.5) + line / 2)
        .environment(\.layoutDirection, .leftToRight)
        .allowsHitTesting(false)
    }
}

private extension Color {
    /// The reference buttons are lit from above: ~18 % white at the top.
    var clockLighter: Color {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        let k = 0.18
        return Color(.sRGB, red: ns.redComponent + (1 - ns.redComponent) * k, green: ns.greenComponent + (1 - ns.greenComponent) * k,
                     blue: ns.blueComponent + (1 - ns.blueComponent) * k, opacity: ns.alphaComponent)
    }
}

/// Circular control: grey secondary (`tint == nil`) or a lit accent primary.
private struct ClockRoundButton: View {
    var symbol: String
    var size: CGFloat
    var iconSize: CGFloat
    var tint: Color? = nil
    var weight: Font.Weight = .semibold
    var flips = false
    var action: () -> Void
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: m.u(iconSize), weight: weight))
                .foregroundStyle(tint == nil ? p.primary.opacity(0.75) : (p.monochrome ? (p.isLight ? Color.white : Color.black) : Color.white))
                .if(flips) { $0.flipsForRTL() }
                .frame(width: m.u(size), height: m.u(size))
                .background {
                    if let tint {
                        let c = p.accent(tint)
                        Circle().fill(LinearGradient(colors: [c.clockLighter, c], startPoint: .top, endPoint: .bottom))
                    } else {
                        Circle().fill(p.controlStrong)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
    }
}

/// Subtle press feedback for whole-tile buttons.
private struct ClockSoftPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Timer

struct ClockTimerTile: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    private var engine: ClockTimerEngine { .shared }

    var body: some View {
        let s = engine.timer(w)
        Tile(width: w.kind.spec.width) {
            if let end = s.end {
                TimelineView(.periodic(from: ClockTime.anchor(before: end), by: 1)) { ctx in content(s, ctx.date) }
            } else {
                content(s, Date())
            }
        }
    }

    private func content(_ s: ClockCountdown, _ now: Date) -> some View {
        ZStack {
            ClockProgressFrame(progress: s.isIdle ? 0 : s.elapsedFraction(at: now), color: p.accent(ClockTint.progress))
            HStack(spacing: 0) {
                Button {
                    Panels.shared.toggle(w.id) { ClockTimerPresetPanel(w: w) }
                } label: {
                    ClockDigits(text: ClockFormat.countdown(s.displaySeconds(at: now)), size: 21.5, weight: .bold)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Choose a duration"))
                Spacer(minLength: m.u(4))
                if !s.isIdle {
                    ClockRoundButton(symbol: "xmark", size: 22, iconSize: 9, weight: .semibold) { engine.cancelTimer(w) }
                        .help(L("Cancel"))
                    Spacer().frame(width: m.u(5))
                }
                ClockRoundButton(symbol: s.isRunning ? "pause.fill" : "play.fill", size: 32, iconSize: 12.5, tint: ClockTint.timer,
                                 flips: !s.isRunning) { engine.toggleTimer(w) }
            }
            .padding(.leading, m.u(19))
            .padding(.trailing, m.u(14))
        }
    }
}

struct ClockTimerPresetPanel: View {
    let w: WidgetInstance
    @Environment(\.palette) private var p

    var body: some View {
        let current = AppStore.shared.widget(w.id)?.int("minutes", 5) ?? w.int("minutes", 5)
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: L("Timer"), subtitle: L("Choose a duration"))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(54), spacing: 8), count: 4), spacing: 8) {
                ForEach(ClockTimerEngine.timerPresets, id: \.self) { minutes in
                    Button {
                        ClockTimerEngine.shared.startTimer(AppStore.shared.widget(w.id) ?? w, minutes: minutes)
                        Panels.shared.close()
                    } label: {
                        VStack(spacing: 0) {
                            Text(Fmt.int(minutes)).font(.dock(18, .bold, mono: true)).foregroundStyle(p.primary)
                            Text(L("min")).font(.dock(10, .semibold)).foregroundStyle(p.secondary)
                        }
                        .frame(width: 54, height: 46)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(minutes == current ? p.accentSoft(ClockTint.timer) : p.control))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
        .frame(width: 240)
    }
}

struct ClockTimerMenu: View {
    let w: WidgetInstance
    private var engine: ClockTimerEngine { .shared }

    var body: some View {
        let s = engine.timer(w)
        Menu(L("Start Timer")) {
            ForEach(ClockTimerEngine.timerPresets, id: \.self) { minutes in
                Button(Fmt.digits(L("%d min", minutes))) { engine.startTimer(w, minutes: minutes) }
            }
        }
        if !s.isIdle {
            Button(s.isRunning ? L("Pause") : L("Resume")) { engine.toggleTimer(w) }
            Button(L("Reset")) { engine.cancelTimer(w) }
        }
        Divider()
    }
}

// MARK: - Stopwatch

struct ClockStopwatchTile: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    private var engine: ClockTimerEngine { .shared }

    var body: some View {
        let s = engine.stopwatch(w.id)
        Tile(width: w.kind.spec.width) {
            if s.isRunning {
                TimelineView(.animation(minimumInterval: 0.1)) { ctx in content(s, ctx.date) }
            } else {
                content(s, Date())
            }
        }
    }

    private func content(_ s: ClockStopwatch, _ now: Date) -> some View {
        let elapsed = s.elapsed(at: now)
        return HStack(spacing: 0) {
            Button {
                Panels.shared.toggle(w.id) { ClockStopwatchPanel(id: w.id) }
            } label: {
                ClockDigits(text: ClockFormat.tenths(elapsed), size: 19, weight: .bold)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Laps"))
            Spacer(minLength: m.u(4))
            ClockRoundButton(symbol: "arrow.counterclockwise", size: 22, iconSize: 9.5) { engine.resetStopwatch(w.id) }
                .opacity(elapsed > 0 ? 1 : 0.45)
                .disabled(elapsed <= 0)
                .help(L("Reset"))
            Spacer().frame(width: m.u(5))
            ClockRoundButton(symbol: s.isRunning ? "pause.fill" : "play.fill", size: 32, iconSize: 12.5, tint: ClockTint.stopwatch,
                             flips: !s.isRunning) { engine.toggleStopwatch(w.id) }
        }
        .padding(.leading, m.u(6.5))
        .padding(.trailing, m.u(14))
    }
}

struct ClockStopwatchPanel: View {
    let id: UUID
    @Environment(\.palette) private var p
    private var engine: ClockTimerEngine { .shared }

    var body: some View {
        let s = engine.stopwatch(id)
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: L("Stopwatch")) {
                Group {
                    if s.isRunning {
                        TimelineView(.animation(minimumInterval: 0.1)) { ctx in elapsed(s, ctx.date) }
                    } else {
                        elapsed(s, Date())
                    }
                }
            }
            if s.laps.isEmpty {
                Text(L("Right-click the stopwatch or press Lap while it runs."))
                    .font(.dock(11, .medium)).foregroundStyle(p.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(s.laps.enumerated().reversed()), id: \.offset) { i, split in
                            let lap = split - (i > 0 ? s.laps[i - 1] : 0)
                            HStack {
                                Text(Fmt.digits(L("Lap %d", i + 1))).font(.dock(12, .semibold)).foregroundStyle(p.secondary)
                                Spacer()
                                Text(verbatim: ClockFormat.tenths(lap)).font(.dock(12, .semibold, mono: true)).foregroundStyle(p.primary)
                                Text(verbatim: ClockFormat.tenths(split)).font(.dock(12, .medium, mono: true)).foregroundStyle(p.tertiary)
                                    .frame(width: 64, alignment: .trailing)
                            }
                            .environment(\.layoutDirection, .leftToRight)
                            .padding(.vertical, 5)
                            Divider().opacity(0.5)
                        }
                    }
                }
                .frame(maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(L("Lap")) { engine.lap(id) }.disabled(!s.isRunning)
                Button(L("Reset")) { engine.resetStopwatch(id) }.disabled(s.elapsed(at: Date()) <= 0)
                Spacer()
                Button(s.isRunning ? L("Pause") : L("Start")) { engine.toggleStopwatch(id) }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .frame(width: 250)
    }

    private func elapsed(_ s: ClockStopwatch, _ now: Date) -> some View {
        Text(verbatim: ClockFormat.tenths(s.elapsed(at: now))).font(.dock(15, .bold, mono: true)).foregroundStyle(p.primary)
    }
}

struct ClockStopwatchMenu: View {
    let w: WidgetInstance
    private var engine: ClockTimerEngine { .shared }

    var body: some View {
        let s = engine.stopwatch(w.id)
        Button(L("Lap")) { engine.lap(w.id) }.disabled(!s.isRunning)
        Button(s.isRunning ? L("Pause") : L("Start")) { engine.toggleStopwatch(w.id) }
        Button(L("Reset")) { engine.resetStopwatch(w.id) }.disabled(!s.isRunning && s.accumulated <= 0)
        Button(L("Show Laps…")) { Panels.shared.show(w.id) { ClockStopwatchPanel(id: w.id) } }
        Divider()
    }
}

// MARK: - Pomodoro

struct ClockPomodoroTile: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    private var engine: ClockTimerEngine { .shared }

    var body: some View {
        let s = engine.pomodoro(w)
        Tile(width: w.kind.spec.width) {
            if let end = s.countdown.end {
                TimelineView(.periodic(from: ClockTime.anchor(before: end), by: 1)) { ctx in content(s, ctx.date) }
            } else {
                content(s, Date())
            }
        }
    }

    private func content(_ s: ClockPomodoro, _ now: Date) -> some View {
        let cfg = ClockPomodoroConfig(w)
        let tint = s.phase == .focus ? ClockTint.focus : ClockTint.rest
        let remaining = s.countdown.duration > 0 ? s.countdown.remaining(at: now) / s.countdown.duration : 1
        return ZStack {
            ClockProgressFrame(progress: remaining, color: p.accent(tint), gradient: true)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: m.u(3.5)) {
                        Text(s.phase.title).dock(9.2, .bold, p.secondary)
                        Text(verbatim: Fmt.digits("\(s.round)/\(cfg.rounds)"))
                            .dock(9.2, .bold, p.primary.opacity(0.27))
                            .environment(\.layoutDirection, .leftToRight)
                    }
                    .fixedSize()
                    ClockDigits(text: ClockFormat.countdown(s.countdown.displaySeconds(at: now)), size: 20.1, weight: .bold)
                }
                .offset(y: m.u(0.5))
                .layoutPriority(1)
                Spacer(minLength: m.u(4))
                ClockRoundButton(symbol: "forward.fill", size: 22, iconSize: 8.5, flips: true) { engine.skipPhase(w) }
                    .help(L("Skip Phase"))
                Spacer().frame(width: m.u(5))
                ClockRoundButton(symbol: s.countdown.isRunning ? "pause.fill" : "play.fill", size: 32, iconSize: 12.5, tint: tint,
                                 flips: !s.countdown.isRunning) { engine.togglePomodoro(w) }
            }
            .padding(.leading, m.u(18))
            .padding(.trailing, m.u(15))
        }
    }
}

struct ClockPomodoroMenu: View {
    let w: WidgetInstance
    private var engine: ClockTimerEngine { .shared }

    var body: some View {
        let s = engine.pomodoro(w)
        Button(s.countdown.isRunning ? L("Pause") : L("Start")) { engine.togglePomodoro(w) }
        Button(L("Skip Phase")) { engine.skipPhase(w) }
        Button(L("Reset")) { engine.resetPomodoro(w) }
        Divider()
    }
}

// MARK: - Drink water & posture

struct ClockReminderTile: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var engine: ClockTimerEngine { .shared }

    private var posture: Bool { w.kind == .posture }

    var body: some View {
        let s = engine.reminder(w.id)
        let paused = s?.isPaused ?? false
        Button {
            engine.confirmReminder(w)
        } label: {
            Tile(width: w.kind.spec.width) {
                if paused {
                    content(s, Date(), animated: false)
                } else if reduceMotion {
                    TimelineView(.periodic(from: ClockTime.alignedSecond(), by: 1)) { ctx in content(s, ctx.date, animated: false) }
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 15)) { ctx in content(s, ctx.date, animated: true) }
                }
            }
        }
        .buttonStyle(ClockSoftPress())
        .help(posture ? L("Click after you sit up straight") : L("Click after you drink a glass of water"))
        .onAppear { engine.registerReminder(w) }
        .onChange(of: w.config) { engine.registerReminder(w) }
    }

    private func content(_ s: ClockReminder?, _ now: Date, animated: Bool) -> some View {
        let interval = TimeInterval(max(1, w.int("interval", posture ? 45 : 30))) * 60
        let state = s ?? ClockReminder(interval: interval, due: now.addingTimeInterval(interval))
        let overdue = state.isOverdue(at: now)
        let level = state.isPaused ? 0.5 : state.level(at: now)
        let colors: [Color] = posture
            ? [p.accent(.cdGreen).opacity(0.42), p.accent(.cdMint).opacity(0.62)]
            : [p.accent(.cdCyan).opacity(0.55), p.accent(ClockTint.water).opacity(0.8)]
        let phase = animated ? now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4 * 2 * .pi : 0
        let minutes = Int(interval / 60)

        return ZStack {
            Canvas { ctx, size in
                ClockWave.draw(ctx, size: size, level: level, phase: phase, front: colors,
                               back: p.primary.opacity(0.13), amplitude: m.u(3))
            }
            .opacity(state.isPaused ? 0.45 : 1)
            HStack(spacing: m.u(7)) {
                if posture {
                    Image(systemName: "figure.stand")
                        .font(.system(size: m.u(24), weight: .semibold))
                        .foregroundStyle(p.clockInk)
                }
                VStack(alignment: posture ? .leading : .center, spacing: m.u(1)) {
                    if overdue {
                        Text(posture ? L("Sit up straight") : L("Drink water"))
                            .dock(posture ? 15 : 17, .bold, p.clockInk)
                            .minimumScaleFactor(0.6)
                    } else {
                        ClockDigits(text: ClockFormat.countdown(ceil(state.remaining(at: now) - 0.05)), size: posture ? 22 : 24, weight: .bold,
                                    color: state.isPaused ? p.secondary : p.primary.opacity(0.9))
                    }
                    Text(state.isPaused ? L("Paused") : Fmt.digits(L("Every %d min", minutes)))
                        .dock(8.9, .bold, p.primary.opacity(0.54))
                        .minimumScaleFactor(0.7)
                }
            }
            .padding(.horizontal, m.u(8))
            .offset(y: m.u(-0.3))
        }
    }
}

private enum ClockWave {
    static func draw(_ ctx: GraphicsContext, size: CGSize, level: Double, phase: Double, front: [Color], back: Color, amplitude: CGFloat) {
        let lvl = CGFloat(min(1, max(0, level)))
        let base = size.height * (1 - lvl)
        let wavelength = size.width * 1.15

        func surface(_ shift: Double, amp: CGFloat, lift: CGFloat) -> Path {
            var path = Path()
            let step = max(2, size.width / 48)
            var x: CGFloat = 0
            path.move(to: CGPoint(x: 0, y: size.height))
            while x <= size.width + step {
                let y = base - lift + amp * CGFloat(sin(Double(x / wavelength) * 2 * .pi + shift))
                path.addLine(to: CGPoint(x: x, y: y))
                x += step
            }
            path.addLine(to: CGPoint(x: size.width + step, y: size.height))
            path.closeSubpath()
            return path
        }

        // Back swell (dim), then the coloured front wave with a left → right gradient.
        ctx.fill(surface(-phase + 2.3, amp: amplitude * 0.9, lift: amplitude * 0.6), with: .color(back))
        ctx.fill(surface(-phase + 4.2, amp: amplitude, lift: 0),
                 with: .linearGradient(Gradient(colors: front), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
    }
}

struct ClockReminderMenu: View {
    let w: WidgetInstance
    private var engine: ClockTimerEngine { .shared }

    var body: some View {
        let s = engine.reminder(w.id)
        let posture = w.kind == .posture
        let count = s?.todayCount(at: Date()) ?? 0
        Button(posture ? L("I Sat Up Straight") : L("I Drank Water")) { engine.confirmReminder(w) }
        Button((s?.isPaused ?? false) ? L("Resume Reminders") : L("Pause Reminders")) { engine.toggleReminderPause(w) }
        Text(Fmt.digits(posture ? L("Today: %d check-ins", count) : L("Today: %d glasses", count)))
        Divider()
    }
}
