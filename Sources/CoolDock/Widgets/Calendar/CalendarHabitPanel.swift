import AppKit
import SwiftUI

enum CalHabitRange: String { case week, weeks }

private enum CalHabitField: Hashable { case add, name(UUID) }

/// Expanded habit tracker: this week or the last 12 weeks per habit, and the editor (add, rename, reorder, delete,
/// symbol, colour, goal). The list scrolls once it would outgrow the screen, so the editor is never clipped.
struct CalHabitPanel: View {
    @Environment(\.palette) private var p
    let w: WidgetInstance
    @State private var editing: Bool
    @State private var range: CalHabitRange
    @State private var expanded: UUID?
    @State private var draft = ""
    /// Names being typed, committed on Return, focus change, Done or close — the store (and so the panel) is not
    /// rewritten per keystroke, which keeps the text field and its focus stable while typing.
    @State private var names: [UUID: String] = [:]
    @State private var confirmDelete: UUID?
    @State private var scroll: CalHabitScrollRequest?
    @FocusState private var focus: CalHabitField?

    init(w: WidgetInstance, editing: Bool, range: CalHabitRange? = nil, expanded: UUID? = nil) {
        self.w = w
        _editing = State(initialValue: editing)
        _range = State(initialValue: range ?? CalHabitRange(rawValue: w.string("view")) ?? .week)
        _expanded = State(initialValue: expanded)
    }

    @MainActor static func toggle(_ w: WidgetInstance, editing: Bool) {
        Panels.shared.toggle(w.id) { CalHabitPanel(w: w, editing: editing) }
    }

    @MainActor static func show(_ w: WidgetInstance, editing: Bool) {
        Panels.shared.show(w.id) { CalHabitPanel(w: w, editing: editing) }
    }

    /// Height the habit list may take before it scrolls: the screen above the dock minus header, add field and margins.
    @MainActor static var listLimit: CGFloat {
        let dock = DockController.shared.activeWindow
        let screen = dock?.screen ?? NSScreen.main
        let room = (screen?.visibleFrame.height ?? 800) - (dock?.panel.frame.height ?? 80)
        return max(160, min(480, room - 190))
    }

    var body: some View {
        let live = AppStore.shared.widget(w.id) ?? w
        let habits = CalHabitStore.habits(live)
        TimelineView(.everyMinute) { ctx in
            let cal = CalHabitClock.calendar
            let today = CalHabitDay(ReferenceScene.date(ctx.date), in: cal)
            VStack(alignment: .leading, spacing: 10) {
                header(habits, today: today)
                if habits.isEmpty {
                    if !editing { empty }
                } else {
                    CalHabitScroll(maxHeight: Self.listLimit, request: scroll) {
                        VStack(spacing: 6) {
                            ForEach(Array(habits.enumerated()), id: \.element.id) { i, h in
                                Group {
                                    if editing {
                                        editorRow(h, index: i, count: habits.count)
                                    } else {
                                        CalHabitPanelRow(habit: h, today: today, calendar: cal, range: range) { day in
                                            CalHabitStore.toggle(w.id, habit: h.id, day: day)
                                        }
                                    }
                                }
                                .id(h.id)
                            }
                        }
                    }
                }
                if editing { addField(count: habits.count) }
            }
        }
        .frame(width: 380)
        .onChange(of: focus) { old, _ in
            if case .name(let id)? = old { commit(id) }
        }
        .onAppear {
            if editing && habits.isEmpty { focusSoon(.add) }
        }
        .onDisappear { commitAll() }
    }

    // MARK: Header

    private func header(_ habits: [CalHabit], today: CalHabitDay) -> some View {
        let done = habits.filter { $0.isChecked(today) }.count
        let subtitle = habits.isEmpty ? L("No habits yet") : L("%@ of %@ done today", Fmt.int(done), Fmt.int(habits.count))
        return PanelHeader(title: L("Habits"), subtitle: subtitle) {
            HStack(spacing: 8) {
                if !editing && !habits.isEmpty {
                    HStack(spacing: 0) {
                        segment(L("Week"), .week)
                        segment(L("12 Weeks"), .weeks)
                    }
                    .padding(2)
                    .background(Capsule().fill(p.control))
                }
                Button { setEditing(!editing) } label: {
                    Text(editing ? L("Done") : LD("habits.edit", "Edit"))
                        .font(.dock(11.5, .semibold))
                        .foregroundStyle(editing ? p.calOnAccent : p.primary)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(Capsule().fill(editing ? p.accent(.cdBlue) : p.control))
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    private func segment(_ title: String, _ r: CalHabitRange) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { range = r }
            AppStore.shared.updateWidget(w.id) { $0.config["view"] = r.rawValue }
        } label: {
            Text(title)
                .font(.dock(10.5, .semibold))
                .foregroundStyle(range == r ? p.primary : p.secondary)
                .padding(.horizontal, 8)
                .frame(height: 18)
                .background(Capsule().fill(range == r ? p.controlStrong : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "flame").font(.system(size: 24, weight: .medium)).foregroundStyle(p.tertiary)
            Text(L("Check off daily habits and keep your streaks going.")).font(.dock(12, .medium)).foregroundStyle(p.secondary)
                .multilineTextAlignment(.center)
            Button { setEditing(true); focusSoon(.add) } label: {
                Text(L("Add a habit")).font(.dock(12, .semibold)).foregroundStyle(p.calOnAccent)
                    .padding(.horizontal, 12).frame(height: 26)
                    .background(Capsule().fill(p.accent(.cdGreen)))
            }
            .buttonStyle(PressableStyle())
        }
        .frame(maxWidth: .infinity, minHeight: 130)
    }

    // MARK: Editor

    private func editorRow(_ h: CalHabit, index i: Int, count: Int) -> some View {
        let open = expanded == h.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(spacing: 2) {
                    reorder("chevron.up", enabled: i > 0, help: L("Move Up")) { move(h.id, by: -1) }
                    reorder("chevron.down", enabled: i < count - 1, help: L("Move Down")) { move(h.id, by: 1) }
                }
                Button { toggleExpanded(h.id) } label: {
                    CalHabitRing(habit: h, progress: 1, done: true, size: 30).contentShape(Circle())
                }
                .buttonStyle(PressableStyle())
                .help(L("Icon, color and goal"))
                nameField(h)
                Button { toggleExpanded(h.id) } label: {
                    HStack(spacing: 4) {
                        Text(verbatim: CalHabitText.goal(h)).lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                    .font(.dock(10.5, .semibold))
                    .foregroundStyle(p.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Capsule().fill(p.primary.opacity(0.07)))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                .fixedSize()
                deleteButton(h)
            }
            if open {
                CalHabitStyleEditor(habit: h) { change in CalHabitStore.update(w.id, habit: h.id, change) }
                    .transition(.opacity)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(p.control.opacity(open ? 0.85 : 0.55)))
    }

    @ViewBuilder private func nameField(_ h: CalHabit) -> some View {
        let binding = Binding(get: { names[h.id] ?? h.name }, set: { names[h.id] = $0 })
        Group {
            if ReferenceScene.isActive {
                // The render harness (ImageRenderer) can't draw AppKit text fields.
                Text(verbatim: binding.wrappedValue).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(L("Name"), text: binding)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .name(h.id))
                    .onSubmit { commit(h.id) }
            }
        }
        .font(.dock(13, .semibold))
        .foregroundStyle(p.primary)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(p.primary.opacity(0.07)))
    }

    @ViewBuilder private func deleteButton(_ h: CalHabit) -> some View {
        if confirmDelete == h.id {
            Button { delete(h.id) } label: {
                Text(L("Delete")).font(.dock(11, .bold)).foregroundStyle(p.calOnAccent)
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(Capsule().fill(p.accent(.cdRed)))
            }
            .buttonStyle(PressableStyle())
            .help(L("Deletes the habit and its history"))
        } else {
            Button { withAnimation(.easeOut(duration: 0.15)) { confirmDelete = h.id } } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(p.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(p.primary.opacity(0.07)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .help(L("Delete"))
        }
    }

    private func reorder(_ symbol: String, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(enabled ? p.secondary : p.tertiary.opacity(0.5))
                .frame(width: 16, height: 13)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        .help(help)
    }

    private func addField(count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(p.accent(.cdGreen))
            if ReferenceScene.isActive {
                Text(L("New Habit")).foregroundStyle(p.tertiary).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(L("New Habit"), text: $draft)
                    .textFieldStyle(.plain)
                    .foregroundStyle(p.primary)
                    .focused($focus, equals: .add)
                    .onSubmit { add(count) }
            }
        }
        .font(.dock(12.5, .medium))
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(p.control))
    }

    // MARK: Actions

    private func setEditing(_ on: Bool) {
        commitAll()
        withAnimation(.easeOut(duration: 0.18)) {
            editing = on
            expanded = nil
            confirmDelete = nil
        }
    }

    private func toggleExpanded(_ id: UUID) {
        commitAll()
        withAnimation(.easeOut(duration: 0.18)) {
            expanded = expanded == id ? nil : id
            confirmDelete = nil
        }
        if expanded == id { scroll = CalHabitScrollRequest(id: id, serial: (scroll?.serial ?? 0) + 1) }
    }

    private func add(_ count: Int) {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let habit = CalHabitStyle.fresh(String(t.prefix(40)), index: count)
        withAnimation(.easeOut(duration: 0.2)) {
            CalHabitStore.mutate(w.id) { $0.append(habit) }
            expanded = habit.id
        }
        draft = ""
        scroll = CalHabitScrollRequest(id: habit.id, serial: (scroll?.serial ?? 0) + 1)
        // Focus stays in the add field so several habits can be typed in a row.
    }

    private func move(_ id: UUID, by delta: Int) {
        commitAll()
        withAnimation(.easeOut(duration: 0.2)) {
            CalHabitStore.mutate(w.id) { list in
                guard let i = list.firstIndex(where: { $0.id == id }), list.indices.contains(i + delta) else { return }
                list.swapAt(i, i + delta)
            }
        }
    }

    private func delete(_ id: UUID) {
        names[id] = nil
        withAnimation(.easeOut(duration: 0.2)) {
            CalHabitStore.mutate(w.id) { $0.removeAll { $0.id == id } }
            if expanded == id { expanded = nil }
            confirmDelete = nil
        }
    }

    private func commit(_ id: UUID) {
        guard let typed = names.removeValue(forKey: id) else { return }
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        CalHabitStore.update(w.id, habit: id) { $0.name = String(t.prefix(40)) }
    }

    private func commitAll() {
        for id in Array(names.keys) { commit(id) }
    }

    /// The panel is already key (`Panels.show` makes it key; it is never the dock), so focus only needs a runloop turn
    /// for the field to exist.
    private func focusSoon(_ field: CalHabitField) {
        DispatchQueue.main.async { focus = field }
    }
}

// MARK: - Rows

private struct CalHabitPanelRow: View {
    @Environment(\.palette) private var p
    var habit: CalHabit
    var today: CalHabitDay
    var calendar: Calendar
    var range: CalHabitRange
    var onToggle: (CalHabitDay) -> Void

    var body: some View {
        let s = CalHabitMath.stats(habit, today: today, firstWeekday: calendar.firstWeekday)
        HStack(spacing: 10) {
            Button { onToggle(today) } label: {
                CalHabitRing(habit: habit, progress: s.progress, done: s.doneToday, size: 32).contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .help(CalHabitText.help(habit, s))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: habit.name).font(.dock(13, .semibold)).foregroundStyle(p.primary).lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(s.current > 0 ? p.accent(.cdOrange) : p.tertiary)
                    Text(verbatim: CalHabitText.streak(s))
                    Text(verbatim: "·").foregroundStyle(p.tertiary)
                    Text(verbatim: range == .week ? CalHabitText.goal(habit) : CalHabitText.best(s))
                }
                .font(.dock(10.5, .semibold))
                .foregroundStyle(p.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if range == .week {
                CalHabitWeekStrip(habit: habit, today: today, calendar: calendar, onToggle: onToggle)
            } else {
                CalHabitHeatGrid(habit: habit, today: today, firstWeekday: calendar.firstWeekday)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(p.control.opacity(0.55)))
    }
}

/// This week, one tappable day per weekday from the calendar's first weekday (Saturday in Persian); past days of the
/// week can be checked after the fact. Follows the reading direction like the calendar week strip.
private struct CalHabitWeekStrip: View {
    @Environment(\.palette) private var p
    var habit: CalHabit
    var today: CalHabitDay
    var calendar: Calendar
    var onToggle: (CalHabitDay) -> Void

    var body: some View {
        let start = today.weekStart(calendar.firstWeekday)
        let accent = p.accent(habit.tint)
        let onAccent = habit.lightTint && !p.monochrome ? Color(white: 0.08) : p.calOnAccent
        let letters = calendar.veryShortStandaloneWeekdaySymbols
        HStack(spacing: 3) {
            ForEach(0..<7, id: \.self) { i in
                let d = start.adding(i)
                let on = habit.isChecked(d)
                let future = d > today
                VStack(spacing: 3) {
                    Text(verbatim: letters.indices.contains(d.weekday - 1) ? letters[d.weekday - 1] : "")
                        .font(.dock(8.5, .bold))
                        .foregroundStyle(d == today ? p.primary : p.tertiary)
                    Button { onToggle(d) } label: {
                        ZStack {
                            Circle().fill(on ? accent : p.primary.opacity(future ? 0.035 : 0.09))
                            if d == today && !on { Circle().strokeBorder(accent.opacity(0.9), lineWidth: 1.5) }
                            if on { Image(systemName: "checkmark").font(.system(size: 7.5, weight: .heavy)).foregroundStyle(onAccent) }
                        }
                        .frame(width: 17, height: 17)
                        .contentShape(Circle())
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(future)
                    .help(Fmt.date(d.date(in: calendar), "EEEEMMMd"))
                }
                .frame(width: 17)
            }
        }
    }
}

/// Last 12 weeks as a contribution grid: columns are weeks (oldest first), rows the weekdays. Charts stay left-to-right.
private struct CalHabitHeatGrid: View {
    @Environment(\.palette) private var p
    var habit: CalHabit
    var today: CalHabitDay
    var firstWeekday: Int

    var body: some View {
        let weeks = CalHabitMath.grid(weeks: 12, today: today, firstWeekday: firstWeekday)
        let checked = habit.checked
        let accent = p.accent(habit.tint)
        let off = p.primary.opacity(0.09)
        Canvas { ctx, size in
            let gap: CGFloat = 1.5
            let cell = min((size.width - gap * 11) / 12, (size.height - gap * 6) / 7)
            for (c, week) in weeks.enumerated() {
                for (r, day) in week.enumerated() where day <= today {
                    let rect = CGRect(x: CGFloat(c) * (cell + gap), y: CGFloat(r) * (cell + gap), width: cell, height: cell)
                    let shape = Path(roundedRect: rect, cornerRadius: cell * 0.3)
                    ctx.fill(shape, with: .color(checked.contains(day) ? accent : off))
                    if day == today && !checked.contains(day) {
                        ctx.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: cell * 0.3), with: .color(accent), lineWidth: 1)
                    }
                }
            }
        }
        .frame(width: 88.5, height: 51)
        .environment(\.layoutDirection, .leftToRight)
        .help(L("Last 12 weeks"))
    }
}

// MARK: - Style editor

private struct CalHabitStyleEditor: View {
    @Environment(\.palette) private var p
    var habit: CalHabit
    var update: (_ change: (inout CalHabit) -> Void) -> Void

    var body: some View {
        let accent = p.accent(habit.tint)
        let onAccent = habit.lightTint && !p.monochrome ? Color(white: 0.08) : p.calOnAccent
        VStack(alignment: .leading, spacing: 8) {
            caption(L("Icon"))
            VStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(CalHabitStyle.symbols[(row * 8)..<(row * 8 + 8)], id: \.self) { symbol in
                            let selected = habit.symbol == symbol
                            Button { update { $0.symbol = symbol } } label: {
                                Image(systemName: symbol)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(selected ? onAccent : p.secondary)
                                    .frame(width: 30, height: 30)
                                    .background(Circle().fill(selected ? accent : p.primary.opacity(0.07)))
                                    .contentShape(Circle())
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                }
            }
            caption(L("Color"))
            HStack(spacing: 7) {
                ForEach(CalHabitStyle.colors, id: \.self) { hex in
                    let selected = habit.color.uppercased() == hex
                    Button { update { $0.color = hex } } label: {
                        Circle().fill(Color(hex: hex))
                            .frame(width: 22, height: 22)
                            .overlay { if selected { Circle().strokeBorder(p.primary, lineWidth: 2).padding(-3.5) } }
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            caption(L("Goal"))
            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    choice(L("Daily"), habit.perWeek == nil) { update { $0.perWeek = nil } }
                    choice(L("Weekly"), habit.perWeek != nil) { update { $0.perWeek = $0.perWeek ?? 3 } }
                }
                .padding(2)
                .background(Capsule().fill(p.primary.opacity(0.07)))
                if let n = habit.weeklyTarget {
                    HStack(spacing: 6) {
                        step("minus", enabled: n > 1) { update { $0.perWeek = max(1, n - 1) } }
                        Text(verbatim: CalHabitText.goal(habit)).font(.dock(11.5, .semibold)).foregroundStyle(p.primary).lineLimit(1)
                        step("plus", enabled: n < 6) { update { $0.perWeek = min(6, n + 1) } }
                    }
                }
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.dock(10.5, .semibold)).foregroundStyle(p.secondary)
    }

    private func choice(_ title: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.dock(11, .semibold))
                .foregroundStyle(on ? p.primary : p.secondary)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(Capsule().fill(on ? p.controlStrong : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func step(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(enabled ? p.primary : p.tertiary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(p.primary.opacity(0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
    }
}

// MARK: - Scrolling

private struct CalHabitScrollRequest: Equatable {
    var id: UUID
    var serial: Int
}

private struct CalHabitHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Sizes to its content and scrolls only beyond `maxHeight` (panels size to their content, so a plain ScrollView would
/// collapse and an unbounded stack would run off the screen).
private struct CalHabitScroll<Content: View>: View {
    var maxHeight: CGFloat
    var request: CalHabitScrollRequest?
    @ViewBuilder var content: () -> Content
    @State private var height: CGFloat = 0

    var body: some View {
        if ReferenceScene.isActive {
            // ImageRenderer can't draw an NSScrollView; scene renders are short enough to show whole.
            content()
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: height > maxHeight) {
                    content()
                        .background(GeometryReader { g in Color.clear.preference(key: CalHabitHeightKey.self, value: g.size.height) })
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(max(height, 1), maxHeight))
                .onPreferenceChange(CalHabitHeightKey.self) { height = $0 }
                .onChange(of: request) { _, r in
                    guard let r else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(r.id) }
                    }
                }
            }
        }
    }
}

// MARK: - Scene previews

extension CalHabitPanel {
    /// `--scene reference` frames `habitTracker-panel`, `-weeks`, `-editor` and `-new` draw the panel instead of the tile,
    /// so the panel can be checked in renders (`Panels` itself needs the running dock).
    static var sceneVariant: String? {
        guard ReferenceScene.isActive, let v = ReferenceScene.variant, ["panel", "weeks", "editor", "new"].contains(v) else { return nil }
        return v
    }

    @MainActor static func scenePreview(_ w: WidgetInstance, variant: String) -> some View {
        let habits = CalHabitStore.habits(w)
        return PanelChrome {
            CalHabitPanel(w: w, editing: variant == "editor", range: variant == "weeks" ? .weeks : .week,
                          expanded: variant == "editor" ? habits.dropFirst().first?.id : nil)
        }
    }
}
