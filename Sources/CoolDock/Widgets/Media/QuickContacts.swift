import AppKit
import Contacts
import Observation
import SwiftUI

/// Plain, sendable copy of the bits of a contact the tile needs.
struct MediaContact: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var initials: String
    var phone: String?
    var email: String?
    var thumbnail: Data? = nil
}

@Observable
@MainActor
final class MediaContactsModel {
    static let shared = MediaContactsModel()

    private(set) var status = CNContactStore.authorizationStatus(for: .contacts)
    private(set) var lists: [String: [MediaContact]] = [:]
    @ObservationIgnored private var images: [String: NSImage] = [:]
    @ObservationIgnored private var inFlight = Set<String>()

    var authorized: Bool {
        status == .authorized
    }

    func refreshStatus() { status = CNContactStore.authorizationStatus(for: .contacts) }

    /// Only ever called from a click — never on appear.
    func requestAccess(then reload: [String]) {
        if status == .notDetermined {
            Task {
                _ = try? await CNContactStore().requestAccess(for: .contacts)
                refreshStatus()
                await load(reload, force: true)
            }
        } else {
            MediaEnv.openPrivacyPane("Privacy_Contacts")
        }
    }

    private func key(_ ids: [String]) -> String { ids.isEmpty ? "#default" : ids.joined(separator: ",") }

    func contacts(_ ids: [String]) -> [MediaContact]? { lists[key(ids)] }

    func image(_ c: MediaContact) -> NSImage? {
        if let hit = images[c.id] { return hit }
        guard let data = c.thumbnail, let cg = MediaImageIO.thumbnail(data: data, maxPixel: 96) else { return nil }
        let img = MediaImageIO.image(cg)
        images[c.id] = img
        return img
    }

    func load(_ ids: [String], force: Bool = false) async {
        refreshStatus()
        let k = key(ids)
        guard authorized, !inFlight.contains(k), force || lists[k] == nil else { return }
        inFlight.insert(k)
        defer { inFlight.remove(k) }
        let result = await Task.detached(priority: .userInitiated) { Self.fetch(ids) }.value
        lists[k] = result
    }

    private nonisolated static func fetch(_ ids: [String]) -> [MediaContact] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
                                       CNContactThumbnailImageDataKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey].map { $0 as CNKeyDescriptor }
        var found: [CNContact] = []
        if ids.isEmpty {
            var fallback: [CNContact] = []
            let req = CNContactFetchRequest(keysToFetch: keys)
            req.sortOrder = .userDefault
            try? store.enumerateContacts(with: req) { c, stop in
                if c.thumbnailImageData != nil { found.append(c) } else if fallback.count < 3 { fallback.append(c) }
                if found.count >= 3 { stop.pointee = true }
            }
            if found.count < 3 { found += fallback.prefix(3 - found.count) }
        } else {
            let fetched = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(withIdentifiers: ids), keysToFetch: keys)) ?? []
            let byID = Dictionary(fetched.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
            found = ids.compactMap { byID[$0] }
        }
        return found.prefix(3).map(convert)
    }

    private nonisolated static func convert(_ c: CNContact) -> MediaContact {
        let full = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        let name = !full.isEmpty ? full : (!c.nickname.isEmpty ? c.nickname : c.organizationName)
        let parts = [c.givenName, c.familyName].filter { !$0.isEmpty }
        let initials = (parts.isEmpty ? [name] : parts).compactMap { $0.first.map(String.init) }.prefix(2).joined().uppercased()
        return MediaContact(id: c.identifier, name: name, initials: initials,
                            phone: c.phoneNumbers.first?.value.stringValue, email: c.emailAddresses.first.map { $0.value as String },
                            thumbnail: c.thumbnailImageData)
    }

    static let demo: [MediaContact] = [
        MediaContact(id: "demo1", name: "Maya Johnson", initials: "MJ", phone: "+1 555 0100", email: "maya@example.com"),
        MediaContact(id: "demo2", name: "Leo Garcia", initials: "LG", phone: "+1 555 0101", email: "leo@example.com"),
        MediaContact(id: "demo3", name: "Noah Becker", initials: "NB", phone: "+1 555 0102", email: "noah@example.com")
    ]
}

// MARK: - Tile (163 pt)

struct MediaContactsTile: View {
    let w: WidgetInstance
    @Environment(\.metrics) private var m

    var body: some View {
        let model = MediaContactsModel.shared
        let ids = w.list("contacts")
        Tile(width: w.kind.spec.width, padding: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 1.5)) {
            if ReferenceScene.isActive {
                avatars(MediaScene.contacts)
            } else if MediaEnv.demo {
                avatars(MediaContactsModel.demo)
            } else if !model.authorized {
                TileMessage(symbol: "person.crop.circle.badge.exclamationmark",
                            text: model.status == .notDetermined ? L("Allow Contacts access") : L("Contacts access off"), tint: .cdGreen)
                    .contentShape(Rectangle())
                    .onTapGesture { model.requestAccess(then: ids) }
            } else if let list = model.contacts(ids) {
                if list.isEmpty {
                    TileMessage(symbol: "person.crop.circle.badge.plus", text: L("Choose contacts"), tint: .cdGreen)
                        .contentShape(Rectangle())
                        .onTapGesture { WidgetSetup.customize(w) }
                } else {
                    avatars(list)
                }
            } else {
                Color.clear
            }
        }
        .task(id: ids) { if !ReferenceScene.isActive { await model.load(ids) } }
        .onWidgetRefresh(w.id) { Task { await model.load(ids, force: true) } }
    }

    private func avatars(_ list: [MediaContact]) -> some View {
        HStack(spacing: m.u(5)) {
            ForEach(list) { c in
                MediaAvatar(contact: c, size: 46)
                    .onTapGesture {
                        Panels.shared.toggle("\(w.id)-\(c.id)") { MediaContactPanel(contact: c) }
                    }
                    .help(c.name)
            }
        }
    }
}

/// Round photo with an Apple-style initials fallback.
private struct MediaAvatar: View {
    @Environment(\.metrics) private var m
    var contact: MediaContact
    var size: CGFloat
    var scaled = true

    var body: some View {
        let s = scaled ? m.u(size) : size
        ZStack {
            if let img = MediaContactsModel.shared.image(contact) {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                Circle().fill(LinearGradient(colors: [Color(hex: "#A8AEB9"), Color(hex: "#80858F")], startPoint: .top, endPoint: .bottom))
                Text(verbatim: contact.initials.isEmpty ? "?" : contact.initials)
                    .font(.system(size: s * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: s, height: s)
        .clipShape(Circle())
        .contentShape(Circle())
    }
}

// MARK: - Panel

private struct MediaContactPanel: View {
    let contact: MediaContact
    @Environment(\.palette) private var p

    var body: some View {
        let phone = contact.phone.map(Self.dialable)
        let handle = phone ?? contact.email
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                MediaAvatar(contact: contact, size: 44, scaled: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.name).font(.dock(15, .bold)).foregroundStyle(p.primary).lineLimit(1)
                    if let sub = contact.phone ?? contact.email {
                        Text(verbatim: sub).font(.dock(11, .medium)).foregroundStyle(p.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                action("video.fill", L("FaceTime"), .cdGreen, handle.map { "facetime://\($0)" })
                action("message.fill", L("Message"), .cdGreen, handle.map { "imessage://\($0)" })
                action("phone.fill", L("Call"), .cdGreen, phone.map { "tel:\($0)" })
                action("envelope.fill", L("Mail"), .cdBlue, contact.email.map { "mailto:\($0)" })
            }
        }
        .frame(width: 264)
    }

    @ViewBuilder private func action(_ symbol: String, _ title: String, _ tint: Color, _ url: String?) -> some View {
        TileIconButton(symbol: symbol, label: title, tint: url == nil ? nil : tint, size: CGSize(width: 60, height: 52)) {
            guard let url else { return }
            Panels.shared.close()
            Open.url(url)
        }
        .opacity(url == nil ? 0.4 : 1)
        .disabled(url == nil)
    }

    static func dialable(_ s: String) -> String {
        String(s.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) || $0 == "+" }.map(Character.init))
    }
}
