import AppKit
import SwiftUI

/// Developer tool: renders widgets to PNG without showing the dock.
///
///     CoolDock --render <outdir> <kind,kind,...|all|category:clocks> [--wait seconds] [--lang fa] [--style darkGlass]
///
/// Output files are `<outdir>/<kind>.png` at 2× scale on the dock plate colour, so they can be
/// compared side by side with the reference frames.
@MainActor
enum RenderHarness {
    /// True for developer renders: services must not trigger permission prompts or AppleScript.
    nonisolated static let isActive = CommandLine.arguments.contains("--render")

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render"), args.count > i + 2 else { return false }
        let outDir = URL(fileURLWithPath: args[i + 1])
        let selector = args[i + 2]
        let wait = value(after: "--wait").flatMap(Double.init) ?? 2.5
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        AppStore.persistenceEnabled = false
        DockFonts.registerBundledFonts()
        let store = AppStore.shared
        if let lang = value(after: "--lang").flatMap(AppLanguage.init(rawValue:)) { store.settings.language = lang }
        if let style = value(after: "--style").flatMap(DockStyle.init(rawValue:)) { store.settings.dockStyle = style }

        let kinds: [WidgetKind]
        if selector == "all" {
            kinds = WidgetKind.allCases
        } else if selector.hasPrefix("category:"), let cat = WidgetCategory(rawValue: String(selector.dropFirst(9))) {
            kinds = WidgetKind.allCases.filter { $0.spec.category == cat }
        } else {
            kinds = selector.split(separator: ",").compactMap { WidgetKind(rawValue: String($0)) }
        }

        // Warm shared services so data-driven widgets have something to show.
        SystemMonitor.shared.subscribe("harness")
        CalendarDemand.events.subscribe("harness")
        CalendarDemand.reminders.subscribe("harness")
        NowPlayingService.shared.start()
        Task { await WeatherService.shared.ensure("") }

        // Mount the widgets offscreen once so `.task` / `.onAppear` loaders run, then render.
        let instances = kinds.map { WidgetInstance(kind: $0) }
        let mount = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 4000, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        mount.contentView = NSHostingView(rootView: HStack(spacing: 6) { ForEach(instances) { WidgetHost(instance: $0) } }
            .environment(\.palette, store.palette).environment(\.metrics, store.metrics))
        mount.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            for w in instances {
                let view = WidgetHost(instance: w)
                    .background(Color(red: 11 / 255, green: 11 / 255, blue: 13 / 255))
                    .environment(\.palette, store.palette)
                    .environment(\.metrics, store.metrics)
                    .environment(\.layoutDirection, store.layoutDirection)
                    .environment(\.locale, Fmt.locale)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let cg = renderer.cgImage {
                    let rep = NSBitmapImageRep(cgImage: cg)
                    try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent("\(w.kind.rawValue).png"))
                }
            }
            print("Rendered \(instances.count) widget(s) to \(outDir.path)")
            exit(0)
        }
        return true
    }

    private static func value(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), args.count > i + 1 else { return nil }
        return args[i + 1]
    }
}
