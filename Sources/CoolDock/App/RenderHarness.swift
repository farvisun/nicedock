import AppKit
import SwiftUI

/// Developer tool: renders widgets to PNG without showing the dock.
///
///     NiceDock --render <outdir> <kind,kind,...|all|category:clocks> [--wait seconds] [--lang fa] [--style darkGlass]
///                       [--scene reference]
///
/// Output files are `<outdir>/<kind>.png` at 2× scale on the dock plate colour, so they can be
/// compared with the reference frames. With `--scene reference` each widget is rendered on its own with the
/// deterministic data of `ReferenceScene` (frame names may carry a variant: `voiceMemo-recording`).
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
        if let radius = value(after: "--radius").flatMap(Double.init) { store.settings.cornerRadius = radius }

        if ReferenceScene.isActive {
            renderScene(selector.split(separator: ",").map(String.init), to: outDir, wait: value(after: "--wait").flatMap(Double.init) ?? 0.6)
            return true
        }

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
                    .background(Color(red: 11 / 255, green: 11 / 255, blue: 11 / 255))
                    .environment(\.palette, store.palette)
                    .environment(\.metrics, store.metrics)
                    .environment(\.layoutDirection, store.layoutDirection)
                    .environment(\.locale, Fmt.locale)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let cg = renderer.cgImage {
                    try? png(cg)?.write(to: outDir.appendingPathComponent("\(w.kind.rawValue).png"))
                }
            }
            print("Rendered \(instances.count) widget(s) to \(outDir.path)")
            exit(0)
        }
        return true
    }

    /// 8-bit sRGB PNG. A frame that contains NSWorkspace app icons comes back from ImageRenderer as 16-bit HDR (PQ);
    /// written as is it reads as washed-out grey, background included. Converting here keeps every frame SDR.
    static func png(_ image: CGImage) -> Data? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }

    /// One widget at a time: seed its reference data, mount it so loaders run, then render.
    private static func renderScene(_ names: [String], to outDir: URL, wait: Double) {
        let store = AppStore.shared
        let frames: [(name: String, kind: WidgetKind, variant: String?)] = names.compactMap { name in
            let parts = name.split(separator: "-", maxSplits: 1).map(String.init)
            guard let kind = WidgetKind(rawValue: parts[0]) else { return nil }
            return (name, kind, parts.count > 1 ? parts[1] : nil)
        }
        let mount = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1600, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        mount.orderFrontRegardless()

        func render(_ index: Int) {
            guard index < frames.count else {
                print("Rendered \(frames.count) widget(s) to \(outDir.path)")
                exit(0)
            }
            let frame = frames[index]
            let config = ReferenceScene.prepare(frame.kind, variant: frame.variant)
            let instance = WidgetInstance(kind: frame.kind, config: config)
            func host() -> some View {
                WidgetHost(instance: instance)
                    .environment(\.palette, store.palette)
                    .environment(\.metrics, store.metrics)
                    .environment(\.layoutDirection, store.layoutDirection)
                    .environment(\.locale, Fmt.locale)
            }
            mount.contentView = NSHostingView(rootView: host())
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                let renderer = ImageRenderer(content: host().background(Color(red: 11 / 255, green: 11 / 255, blue: 11 / 255)))
                renderer.scale = 2
                if let cg = renderer.cgImage {
                    try? png(cg)?.write(to: outDir.appendingPathComponent("\(frame.name).png"))
                }
                mount.contentView = nil
                render(index + 1)
            }
        }
        render(0)
    }

    private static func value(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), args.count > i + 1 else { return nil }
        return args[i + 1]
    }
}
