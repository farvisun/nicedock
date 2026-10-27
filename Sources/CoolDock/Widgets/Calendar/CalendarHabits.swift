import AppKit
import SwiftUI

// MARK: - Store

/// Habits and their check-ins live in the widget's config (`habits`, JSON), so they persist with the dock profile.
@MainActor
enum CalHabitStore {
    static func habits(_ w: WidgetInstance?) -> [CalHabit] { decode(w?.config["habits"]) }

    nonisolated static func decode(_ raw: String?) -> [CalHabit] {
        guard let raw, let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([CalHabit].self, from: data)) ?? []
    }

    nonisolated static func encode(_ list: [CalHabit]) -> String {
        (try? JSONEncoder().encode(list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    static func mutate(_ id: UUID, _ change: (inout [CalHabit]) -> Void) {
        guard let w = AppStore.shared.widget(id) else { return }
        var list = habits(w)
        change(&list)
        let json = encode(list)
        AppStore.shared.updateWidget(id) { $0.config["habits"] = json }
    }

    static func update(_ id: UUID, habit: UUID, _ change: (inout CalHabit) -> Void) {
        mutate(id) { list in
            if let i = list.firstIndex(where: { $0.id == habit }) { change(&list[i]) }
        }
    }

    static func toggle(_ id: UUID, habit: UUID, day: CalHabitDay) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
            update(id, habit: habit) { $0.toggle(day) }
        }
    }
}

enum CalHabitText {
    static func streak(_ s: CalHabitStats) -> String {
        switch s.unit {
        case .days: return s.current == 1 ? L("1 day") : L("%@ days", Fmt.int(s.current))
        case .weeks: return s.current == 1 ? L("1 week") : L("%@ weeks", Fmt.int(s.current))
        }
    }

    static func best(_ s: CalHabitStats) -> String {
        let n = s.best
        let value: String
        switch s.unit {
        case .days: value = n == 1 ? L("1 day") : L("%@ days", Fmt.int(n))
        case .weeks: value = n == 1 ? L("1 week") : L("%@ weeks", Fmt.int(n))
        }
        return L("Best: %@", value)
    }

    static func goal(_ h: CalHabit) -> String {
        guard let n = h.weeklyTarget else { return L("Every day") }
        return n == 1 ? L("Once a week") : L("%@ days a week", Fmt.int(n))
    }

    /// Tooltip of a check circle: name, streak and what a click does.
    static func help(_ h: CalHabit, _ s: CalHabitStats) -> String {
        "\(h.name) · \(streak(s))\n" + (s.doneToday ? L("Click to undo today") : L("Click to check off today"))
    }
}

extension CalHabit {
    var tint: Color { Color(hex: color) }
    /// Light accents (yellow, mint) carry a dark glyph once filled.
    var lightTint: Bool {
        let ns = NSColor(tint).usingColorSpace(.sRGB) ?? .black
        return 0.299 * ns.redComponent + 0.587 * ns.greenComponent + 0.114 * ns.blueComponent > 0.72
    }
}

// MARK: - Check ring

/// Habit button: soft disc with the habit's symbol, filled once today is checked; the ring shows today (daily habits)
/// or the week's goal (weekly habits).
struct CalHabitRing: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var habit: CalHabit
    var progress: Double
    var done: Bool
    var size: CGFloat = 36

    var body: some View {
        let accent = p.accent(habit.tint)
        let line = m.u(size * 0.07)
        let gap = m.u(size * 0.056)
        let onAccent = habit.lightTint && !p.monochrome ? Color(white: 0.08) : p.calOnAccent
        ZStack {
            Circle().stroke(accent.opacity(0.22), lineWidth: line).padding(line / 2)
            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(accent, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(line / 2)
            Circle().fill(done ? accent : accent.opacity(0.15)).padding(line + gap)
            Image(systemName: habit.symbol)
                .font(.system(size: m.u(size * 0.34), weight: .semibold))
                .foregroundStyle(done ? onAccent : accent)
        }
        .frame(width: m.u(size), height: m.u(size))
        // Rings fill clockwise from 12 o'clock in every language.
        .environment(\.layoutDirection, .leftToRight)
    }
}

// MARK: - Tile

struct CalHabitWidget: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    let w: WidgetInstance

    /// Circles the tile shows before the rest move behind a "+N" circle.
    static let maxCells = 6
    static let emptyWidth: CGFloat = 168

    /// Whole-point width for `cells` circles: 12 pt padding, 36 pt circles, 8 pt gaps (the Quick Toggles rhythm).
    static func width(cells: Int) -> CGFloat {
        cells == 0 ? emptyWidth : max(62, CGFloat(24 + cells * 36 + (cells - 1) * 8))
    }

    var body: some View {
        if let variant = CalHabitPanel.sceneVariant {
            CalHabitPanel.scenePreview(w, variant: variant)
        } else {
            tile
        }
    }

    private var tile: some View {
        let habits = CalHabitStore.habits(w)
        return TimelineView(.everyMinute) { ctx in
            let cal = CalHabitClock.calendar
            let today = CalHabitDay(ReferenceScene.date(ctx.date), in: cal)
            let visible = habits.count > Self.maxCells ? Array(habits.prefix(Self.maxCells - 1)) : habits
            let overflow = habits.count - visible.count
            if habits.isEmpty {
                Tile(width: Self.emptyWidth) { CalHabitEmptyTile() }
                    .onTapGesture { open(editing: true) }
                    .help(L("Add a habit"))
            } else {
                Tile(width: Self.width(cells: visible.count + (overflow > 0 ? 1 : 0))) {
                    HStack(spacing: m.u(8)) {
                        ForEach(visible) { h in cell(h, today: today, firstWeekday: cal.firstWeekday) }
                        if overflow > 0 { more(overflow) }
                    }
                }
                .onTapGesture { open(editing: false) }
            }
        }
    }

    private func cell(_ h: CalHabit, today: CalHabitDay, firstWeekday: Int) -> some View {
        let s = CalHabitMath.stats(h, today: today, firstWeekday: firstWeekday)
        let id = w.id
        return VStack(spacing: m.u(2.5)) {
            Button { CalHabitStore.toggle(id, habit: h.id, day: today) } label: {
                CalHabitRing(habit: h, progress: s.progress, done: s.doneToday).contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .help(CalHabitText.help(h, s))
            .accessibilityLabel(h.name)
            CalHabitStreakLabel(stats: s)
        }
        .frame(width: m.u(36))
    }

    /// "+N" circle for habits that don't fit; opens the panel.
    private func more(_ count: Int) -> some View {
        VStack(spacing: m.u(2.5)) {
            Button { open(editing: false) } label: {
                Text(verbatim: "+" + Fmt.int(count)).dock(12, .bold, p.secondary)
                    .frame(width: m.u(36), height: m.u(36))
                    .background(Circle().fill(p.primary.opacity(0.065)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .help(L("Show Habits…"))
            Color.clear.frame(height: m.u(10))
        }
    }

    private func open(editing: Bool) {
        CalHabitPanel.toggle(w, editing: editing)
    }
}

/// Flame and current streak under a tile circle (dimmed at zero).
private struct CalHabitStreakLabel: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    var stats: CalHabitStats

    var body: some View {
        let on = stats.current > 0
        HStack(spacing: m.u(1.5)) {
            Image(systemName: "flame.fill")
                .font(.system(size: m.u(7.5), weight: .bold))
                .foregroundStyle(on ? p.accent(.cdOrange) : p.tertiary)
            Text(verbatim: Fmt.int(stats.current)).dock(9, .bold, on ? p.secondary : p.tertiary, mono: true)
        }
        .frame(height: m.u(10))
        .environment(\.layoutDirection, .leftToRight)
    }
}

private struct CalHabitEmptyTile: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: m.u(8)) {
            Image(systemName: "plus.circle.fill").font(.system(size: m.u(19), weight: .semibold)).foregroundStyle(p.accent(.cdGreen))
            VStack(alignment: .leading, spacing: m.u(1)) {
                Text(L("Add a habit")).dock(11.5, .bold).minimumScaleFactor(0.8)
                Text(L("Build a daily streak")).dock(9.5, .semibold, p.secondary).minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, m.u(12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}
