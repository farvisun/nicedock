import AppKit
import SwiftUI

/// 207 pt Spotlight search tile. The text field only exists while editing (cheap at rest, and the
/// dock panel becomes key just for that); results appear in a panel and the query stops when done.
struct AppsFindTile: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    @Environment(\.layoutDirection) private var direction
    let w: WidgetInstance
    @State private var query = ""
    @State private var editing = false
    @State private var search = AppsSpotlight()
    @State private var host: NSWindow?
    @FocusState private var focused: Bool

    var body: some View {
        Tile(width: w.kind.spec.width, padding: EdgeInsets(top: 0, leading: 6.5, bottom: 0, trailing: 7.75)) {
            HStack(spacing: 0) {
                Image(systemName: "folder.fill")
                    .font(.system(size: m.u(14.2), weight: .medium))
                    .foregroundStyle(p.appsGlyph)
                    .frame(width: m.u(16))
                ZStack(alignment: .leading) {
                    if query.isEmpty {
                        Text(L("Find files…")).dock(13.25, .semibold, p.primary.opacity(0.25))
                            .allowsHitTesting(false)
                    }
                    if editing {
                        TextField("", text: $query)
                            .textFieldStyle(.plain)
                            .font(.dock(m.u(13.25), .semibold))
                            .foregroundStyle(p.primary)
                            .focused($focused)
                            .onSubmit(submit)
                            .onExitCommand(perform: cancel)
                    }
                }
                .padding(.leading, m.u(9))
                .padding(.trailing, m.u(6))
                .frame(maxWidth: .infinity, alignment: .leading)
                CircleButton(symbol: direction == .rightToLeft ? "arrow.left" : "arrow.right", size: 18.5,
                             fill: p.primary.opacity(0.24), foreground: p.primary, iconScale: 0.56, action: submit)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: beginEditing)
        .onChange(of: focused) { _, now in
            if !now && query.isEmpty { editing = false }
        }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard q.count >= 2 else {
                search.clear()
                closeResults()
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            run(q)
        }
        .onDisappear {
            search.clear()
            closeResults()
        }
    }

    private func beginEditing() {
        guard !editing else { focused = true; return }
        editing = true
        let window = NSApp.currentEvent?.window
        host = window
        window?.makeKey()
        DispatchQueue.main.async { focused = true }
    }

    private func submit() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { beginEditing(); return }
        if search.term == q, !search.searching, let first = search.hits.first {
            open(first.url)
        } else {
            run(q)
        }
    }

    private func cancel() {
        query = ""
        editing = false
        focused = false
        search.clear()
        closeResults()
    }

    private func run(_ q: String) {
        search.find(q)
        showResults()
    }

    private func open(_ url: URL) {
        AppsFileOps.open(url)
        cancel()
    }

    private func showResults() {
        if Panels.shared.isOpen, Panels.shared.currentID == AnyHashable(w.id) { return }
        let search = search
        Panels.shared.show(w.id) {
            AppsFindResults(search: search) { url in open(url) }
        }
        // Keep typing in the dock: the results panel must not steal keyboard focus.
        if editing { (host ?? NSApp.windows.first { $0 is DockPanel })?.makeKey() }
    }

    private func closeResults() {
        if Panels.shared.currentID == AnyHashable(w.id) { Panels.shared.close() }
    }
}

private struct AppsFindResults: View {
    @Environment(\.palette) private var p
    let search: AppsSpotlight
    let open: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: L("Files"), subtitle: search.term.isEmpty ? nil : "“\(search.term)”") {
                if !search.term.isEmpty {
                    AppsPanelButton(symbol: "magnifyingglass", title: L("Show All in Finder")) {
                        NSWorkspace.shared.showSearchResults(forQueryString: search.term)
                        Panels.shared.close()
                    }
                }
            }
            if search.hits.isEmpty {
                if search.searching {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 90)
                } else {
                    AppsPanelMessage(symbol: "doc.text.magnifyingglass", text: L("No files found"), height: 90)
                }
            } else {
                AppsScroll(height: CGFloat(search.hits.count) * 42, max: 42 * 9) {
                    LazyVStack(spacing: 0) {
                        ForEach(search.hits) { hit in
                            AppsFileRow(url: hit.url, title: hit.name,
                                        detail: AppsFS.abbreviated(hit.url.deletingLastPathComponent().path)) {
                                open(hit.url)
                            }
                            .contextMenu {
                                Button(L("Open")) { open(hit.url) }
                                Button(L("Show in Finder")) { Open.reveal(hit.url.path); Panels.shared.close() }
                            }
                        }
                    }
                }
                Text(L("Return opens the first result · ⌘-click shows in Finder"))
                    .font(.dock(10.5, .medium)).foregroundStyle(p.tertiary)
            }
        }
        .frame(width: 380)
    }
}
