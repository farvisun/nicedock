import AppKit
import Contacts
import SwiftUI

/// Add/customize flow. Widgets with required choices (accounts, tokens, apps) show a setup panel first.
@MainActor
enum WidgetSetup {
    private static let host = WindowHost(id: "setup")

    static func add(_ kind: WidgetKind, at index: Int? = nil) {
        let spec = kind.spec
        if kind == .app {
            for url in FilePickers.apps(multiple: true) { AppStore.shared.addWidget(.app, config: ["path": url.path], at: index) }
            return
        }
        if spec.connected {
            present(WidgetInstance(kind: kind), isNew: true, index: index)
            return
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { AppStore.shared.addWidget(kind, at: index) }
    }

    static func customize(_ w: WidgetInstance) {
        present(w, isNew: false, index: nil)
    }

    private static func present(_ w: WidgetInstance, isNew: Bool, index: Int?) {
        Panels.shared.close()
        let title = isNew ? L("Add %@", w.kind.spec.localizedTitle) : L("Customize %@", w.kind.spec.localizedTitle)
        host.show(title: title, size: NSSize(width: 520, height: 600), minSize: NSSize(width: 460, height: 380), level: .floating) {
            WidgetSetupView(draft: w, isNew: isNew, index: index) { host.close() }
        }
    }
}

struct WidgetSetupView: View {
    @State var draft: WidgetInstance
    let isNew: Bool
    let index: Int?
    var dismiss: () -> Void
    @State private var secrets: [String: String] = [:]
    private var store: AppStore { .shared }

    var body: some View {
        let spec = draft.kind.spec
        VStack(spacing: 0) {
            ZStack {
                WallpaperBackdrop()
                WidgetHost(instance: draft)
                    .allowsHitTesting(false)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(store.palette.plate == .clear ? Color.black.opacity(0.35) : store.palette.plate))
                    .environment(\.palette, store.palette)
                    .environment(\.metrics, DockMetrics(scale: min(1, 420 / max(spec.width, 1)), spacing: 6, cornerRadius: store.settings.cornerRadius))
                    .id(draft.config)
            }
            .frame(height: 130)
            .padding(.top, 28)

            Form {
                Section {
                    HStack(spacing: 10) {
                        SettingsIcon(symbol: spec.symbol, tint: spec.category.tint, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(spec.localizedTitle).font(.ui(14, .semibold))
                            Text(spec.localizedSummary).font(.ui(11.5)).foregroundStyle(.secondary)
                        }
                    }
                }
                if !spec.fields.isEmpty {
                    Section(spec.connected ? L("Connection") : L("Options")) {
                        ForEach(spec.fields, id: \.key) { field in fieldView(field) }
                    }
                }
                if !spec.visibility.isEmpty {
                    Section(L("Visibility")) {
                        Picker(L("Show"), selection: $draft.visibility) {
                            ForEach([VisibilityRule.always] + spec.visibility) { Text($0.title).tag($0) }
                        }
                    }
                }
                if spec.connected {
                    Section {
                        Label(L("Credentials are stored only on this Mac, in your login Keychain."), systemImage: "lock.shield")
                            .font(.ui(11.5)).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if !isNew {
                    Button(L("Remove Widget"), role: .destructive) { store.removeWidget(draft.id); dismiss() }
                }
                Spacer()
                Button(L("Cancel"), action: dismiss).keyboardShortcut(.cancelAction)
                Button(isNew ? L("Add Widget") : L("Save"), action: save).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .onAppear {
            for f in spec.fields { if case .secret = f.type { secrets[f.key] = Secrets.get(draft.id, f.key) ?? "" } }
        }
    }

    private func save() {
        for (k, v) in secrets { Secrets.set(v.trimmingCharacters(in: .whitespacesAndNewlines), draft.id, k) }
        if isNew {
            store.updateActive { p in
                if let index, index <= p.widgets.count { p.widgets.insert(draft, at: index) } else { p.widgets.append(draft) }
            }
        } else {
            store.updateWidget(draft.id) { $0 = draft }
        }
        NotificationCenter.default.post(name: .coolDockRefresh, object: draft.id)
        dismiss()
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { draft.string(key) }, set: { draft.config[key] = $0 })
    }

    @ViewBuilder
    private func fieldView(_ f: ConfigField) -> some View {
        switch f.type {
        case .text(let placeholder):
            TextField(L(f.title), text: binding(f.key), prompt: Text(placeholder))
                .help(f.help.map(L) ?? "")
        case .multiline(let placeholder):
            VStack(alignment: .leading, spacing: 4) {
                Text(L(f.title))
                TextEditor(text: binding(f.key))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 90)
                    .overlay(alignment: .topLeading) {
                        if draft.string(f.key).isEmpty { Text(placeholder).foregroundStyle(.tertiary).padding(6).allowsHitTesting(false) }
                    }
            }
        case .secret(let placeholder):
            VStack(alignment: .leading, spacing: 3) {
                SecureField(L(f.title), text: Binding(get: { secrets[f.key] ?? "" }, set: { secrets[f.key] = $0 }), prompt: Text(placeholder))
                if let help = f.help { Text(L(help)).font(.ui(10.5)).foregroundStyle(.secondary) }
            }
        case .number(let min, let max, let step, let unit):
            let value = Binding<Double>(get: { draft.double(f.key, min) }, set: { draft.config[f.key] = $0 == $0.rounded() ? String(Int($0)) : String($0) })
            Stepper(value: value, in: min...max, step: step) {
                HStack {
                    Text(L(f.title))
                    Spacer()
                    Text(Fmt.number(value.wrappedValue, decimals: step < 1 ? 1 : 0) + (unit.isEmpty ? "" : " " + L(unit))).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        case .toggle:
            Toggle(L(f.title), isOn: Binding(get: { draft.bool(f.key) }, set: { draft.config[f.key] = $0 ? "1" : "0" }))
        case .choice(let options):
            Picker(L(f.title), selection: binding(f.key)) {
                ForEach(options, id: \.value) { Text(L($0.title)).tag($0.value) }
            }
        case .color:
            ColorPicker(L(f.title), selection: Binding(get: { Color(hex: draft.string(f.key, "#30D158")) }, set: { draft.config[f.key] = $0.hexString }), supportsOpacity: false)
        case .app:
            HStack {
                Text(L(f.title))
                Spacer()
                let path = draft.string(f.key)
                if !path.isEmpty {
                    Image(nsImage: IconCache.icon(path: path, size: 18)).resizable().frame(width: 18, height: 18)
                    Text(FileManager.default.displayName(atPath: path)).foregroundStyle(.secondary)
                }
                Button(L("Choose…")) { if let url = FilePickers.apps(multiple: false).first { draft.config[f.key] = url.path } }
            }
        case .apps:
            AppListEditor(paths: Binding(get: { draft.list(f.key) }, set: { draft.config[f.key] = $0.joined(separator: "\n") }), title: L(f.title))
        case .folder:
            HStack {
                Text(L(f.title))
                Spacer()
                Text((draft.string(f.key) as NSString).abbreviatingWithTildeInPath).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button(L("Choose…")) { if let url = FilePickers.folder(start: draft.string(f.key)) { draft.config[f.key] = url.path } }
            }
        case .city:
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    TextField(L(f.title), text: binding(f.key), prompt: Text(L("Current location")))
                    if !draft.string(f.key).isEmpty {
                        Button(L("Use Current Location")) { draft.config[f.key] = "" }
                    }
                }
                Text(L("City name, or latitude,longitude.")).font(.ui(10.5)).foregroundStyle(.secondary)
            }
        case .contacts:
            ContactPickerList(selected: Binding(get: { draft.list(f.key) }, set: { draft.config[f.key] = $0.joined(separator: "\n") }))
        }
    }
}

struct AppListEditor: View {
    @Binding var paths: [String]
    var title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Button { paths += FilePickers.apps(multiple: true).map(\.path).filter { !paths.contains($0) } } label: { Label(L("Add Apps…"), systemImage: "plus") }
            }
            ForEach(paths, id: \.self) { path in
                HStack(spacing: 8) {
                    Image(nsImage: IconCache.icon(path: path, size: 20)).resizable().frame(width: 20, height: 20)
                    Text(FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""))
                    Spacer()
                    Button { if let i = paths.firstIndex(of: path), i > 0 { paths.swapAt(i, i - 1) } } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                    Button { paths.removeAll { $0 == path } } label: { Image(systemName: "minus.circle.fill").foregroundStyle(Color.cdRed) }.buttonStyle(.borderless)
                }
            }
        }
    }
}

struct ContactPickerList: View {
    @Binding var selected: [String]
    @State private var contacts: [(id: String, name: String)] = []
    @State private var query = ""
    @State private var denied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if denied {
                Text(L("Allow Contacts access in Settings → Privacy & Permissions.")).foregroundStyle(.secondary)
            } else {
                TextField(L("Search contacts"), text: $query)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(contacts.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.prefix(200), id: \.id) { c in
                            Toggle(c.name, isOn: Binding(get: { selected.contains(c.id) }, set: { on in
                                if on { if selected.count < 6 { selected.append(c.id) } } else { selected.removeAll { $0 == c.id } }
                            }))
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .frame(height: 160)
                Text(L("Up to six contacts.")).font(.ui(10.5)).foregroundStyle(.secondary)
            }
        }
        .task { await load() }
    }

    private func load() async {
        let store = CNContactStore()
        let ok = (try? await store.requestAccess(for: .contacts)) ?? false
        guard ok else { denied = true; return }
        let result: [(String, String)] = await Task.detached {
            var out: [(String, String)] = []
            let req = CNContactFetchRequest(keysToFetch: [CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor, CNContactIdentifierKey as CNKeyDescriptor])
            req.sortOrder = .userDefault
            try? store.enumerateContacts(with: req) { c, stop in
                let name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                if !name.isEmpty { out.append((c.identifier, name)) }
                if out.count > 2000 { stop.pointee = true }
            }
            return out
        }.value
        contacts = result.map { (id: $0.0, name: $0.1) }
    }
}
