import AppKit
import SwiftUI

/// First-run walkthrough: language, layout, a starter profile and optional permissions.
@MainActor
enum OnboardingWindow {
    private static let host = WindowHost(id: "onboarding")

    static func show() {
        host.show(title: "", size: NSSize(width: 720, height: 560), resizable: false) {
            OnboardingView { host.close() }.id(AppStore.shared.languageRevision)
        }
    }

    static func refresh() { if host.isVisible { show() } }
}

struct OnboardingView: View {
    var finish: () -> Void
    @State private var step = 0
    @State private var showLiveApps = false
    private var store: AppStore { .shared }
    private let steps = 4

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case 0: welcome
                case 1: language
                case 2: layout
                default: ready
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            .id(step)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<steps, id: \.self) { i in
                        Capsule().fill(i == step ? Color.accentColor : Color.primary.opacity(0.15)).frame(width: i == step ? 18 : 6, height: 6)
                    }
                }
                Spacer()
                if step > 0 { Button(L("Back")) { withAnimation(.easeOut(duration: 0.25)) { step -= 1 } } }
                Button(step == steps - 1 ? L("Start Using NiceDock") : L("Continue")) {
                    if step == steps - 1 { complete() } else { withAnimation(.easeOut(duration: 0.25)) { step += 1 } }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(20)
        }
        .onReceive(NotificationCenter.default.publisher(for: .coolDockLanguageChanged)) { _ in
            DispatchQueue.main.async { OnboardingWindow.refresh() }
        }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            ZStack(alignment: .bottom) {
                WallpaperBackdrop()
                HeroDockSample().padding(.bottom, 22)
            }
            .frame(height: 230)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 30)
            .padding(.top, 34)
            Text(L("Your smart second Dock")).font(.ui(13, .semibold)).foregroundStyle(Color.accentColor)
            Text(L("A useful Dock for live widgets.")).font(.ui(28, .bold)).multilineTextAlignment(.center)
            Text(L("Music, todos, events, weather, search, stats, quick actions and more — in one beautiful live dock beside your Mac Dock."))
                .font(.ui(14)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
        }
    }

    private var language: some View {
        VStack(spacing: 18) {
            Image(systemName: "globe").font(.system(size: 40)).foregroundStyle(Color.accentColor).padding(.top, 36)
            Text(L("Choose your language")).font(.ui(24, .bold))
            Text(L("NiceDock speaks your language — including Persian with the Estedad typeface and the Solar Hijri calendar."))
                .font(.ui(13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(150), spacing: 10), count: 4), spacing: 10) {
                ForEach(AppLanguage.allCases.filter { $0 != .system }) { lang in
                    let selected = store.resolvedLanguage == lang
                    Button { store.settings.language = lang } label: {
                        Text(lang.nativeName)
                            .font(lang.usesEstedad ? .custom("Estedad-SemiBold", size: 14) : .system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            LanguagePreview().frame(width: 520)
        }
    }

    private var layout: some View {
        VStack(spacing: 16) {
            Text(L("Where should NiceDock live?")).font(.ui(24, .bold)).padding(.top, 30)
            Text(L("You can change this any time in Settings → Layout.")).font(.ui(13)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach([LayoutScenario.swapBottom, .fixed, .revealBottom, .floating]) { sc in
                    ScenarioCard(scenario: sc, selected: store.settings.scenario == sc) { store.settings.scenario = sc }
                }
            }
            .frame(maxWidth: 620)
            Toggle(L("Show live apps"), isOn: Binding(get: { store.settings.runningApps != .hidden }, set: { store.settings.runningApps = $0 ? .right : .hidden }))
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 30)
    }

    private var ready: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 52)).foregroundStyle(Color.cdGreen).padding(.top, 50)
            Text(L("You're all set")).font(.ui(26, .bold))
            VStack(alignment: .leading, spacing: 10) {
                tip("cursorarrow.click.2", L("Right-click the Dock or any widget for options."))
                tip("square.grid.2x2", L("Open Widgets to add more — or drag a card straight into the Dock."))
                tip("command", L("Hold ⌘ and drag to reorder. Press ⌃⌥⌘D to hide or show NiceDock."))
                tip("person.2.crop.square.stack", L("Hover the Dock to switch between profiles."))
            }
            .frame(maxWidth: 460)
        }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.accentColor).frame(width: 26)
            Text(text).font(.ui(13))
        }
    }

    private func complete() {
        store.settings.onboardingDone = true
        finish()
    }
}

/// Static replica of the cooldock.app hero dock (time, weather, apps, progress, music).
struct HeroDockSample: View {
    private var store: AppStore { .shared }

    var body: some View {
        let widgets: [WidgetInstance] = [
            WidgetInstance(kind: .timeHero), WidgetInstance(kind: .weatherHero),
            WidgetInstance(kind: .appFolder, config: ["apps": "/Applications/Safari.app\n/System/Applications/Music.app\n/System/Applications/Notes.app\n/System/Applications/Calendar.app"]),
            WidgetInstance(kind: .progressRing)
        ]
        let m = DockMetrics(scale: 0.9, spacing: 6, cornerRadius: 12)
        let shape = RoundedRectangle(cornerRadius: m.plateRadius, style: .continuous)
        HStack(spacing: m.gap) {
            ForEach(widgets) { WidgetHost(instance: $0).allowsHitTesting(false) }
        }
        .padding(m.padding)
        .background(shape.fill(Color.black.opacity(0.9)))
        .overlay(shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 5)
        .environment(\.palette, DockPalette.make(style: .darkGlass, surface: .glass, monochrome: false, tiles: true, reduceTransparency: true))
        .environment(\.metrics, m)
        .environment(\.layoutDirection, store.layoutDirection)
    }
}
