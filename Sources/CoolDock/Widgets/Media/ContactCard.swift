import SwiftUI

// MARK: - Contact card (203 pt)

/// One person: round avatar followed by Call, FaceTime video, FaceTime audio and Message buttons.
///
/// Shares `MediaContactsModel` (loader + thumbnail cache) and `MediaAvatar` with Quick Contacts. Contacts
/// is only read once the user has picked someone, so an unconfigured card never asks for permission.
struct MediaContactCardTile: View {
    let w: WidgetInstance

    var body: some View {
        let model = MediaContactsModel.shared
        let ids = Array(w.list("contact").prefix(1))
        Tile(width: w.kind.spec.width, padding: EdgeInsets(top: 0, leading: 3.25, bottom: 0, trailing: 0), alignment: .leading) {
            if ReferenceScene.isActive, let contact = MediaScene.contacts.first {
                MediaContactCard(contact: contact)
            } else if MediaEnv.demo {
                MediaContactCard(contact: MediaContactsModel.demo[0])
            } else if ids.isEmpty {
                prompt("person.crop.circle.badge.plus", L("Choose a contact")) { WidgetSetup.customize(w) }
            } else if !model.authorized {
                prompt("person.crop.circle.badge.exclamationmark",
                       model.status == .notDetermined ? L("Allow Contacts access") : L("Contacts access off")) { model.requestAccess(then: ids) }
            } else if let list = model.contacts(ids) {
                if let contact = list.first {
                    MediaContactCard(contact: contact)
                } else {
                    // The chosen contact was deleted or merged away.
                    prompt("person.crop.circle.badge.plus", L("Choose a contact")) { WidgetSetup.customize(w) }
                }
            } else {
                Color.clear
            }
        }
        .task(id: ids) { if !ReferenceScene.isActive, !ids.isEmpty { await model.load(ids) } }
        .onWidgetRefresh(w.id) { if !ids.isEmpty { Task { await model.load(ids, force: true) } } }
    }

    private func prompt(_ symbol: String, _ text: String, action: @escaping () -> Void) -> some View {
        TileMessage(symbol: symbol, text: text, tint: .cdGreen)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    /// Right-click items: the same four actions as the buttons, then the person in Contacts.
    @MainActor @ViewBuilder
    static func menu(_ w: WidgetInstance) -> some View {
        let ids = Array(w.list("contact").prefix(1))
        if !ids.isEmpty, let contact = MediaContactsModel.shared.contacts(ids)?.first {
            ForEach(MediaContactAction.allCases) { action in
                if let url = action.url(for: contact) {
                    Button(action.title) { Open.url(url) }
                }
            }
            Divider()
            Button(L("Open Contacts")) { MediaContactAction.reveal(contact) }
        } else {
            Button(L("Open Contacts")) { Open.bundle("com.apple.AddressBook") }
        }
        Divider()
    }
}

/// The four round actions, in the order the card shows them.
enum MediaContactAction: CaseIterable, Identifiable {
    case call, video, audio, message

    var id: Self { self }

    var title: String {
        switch self {
        case .call: return L("Call")
        case .video: return L("FaceTime")
        case .audio: return L("FaceTime Audio")
        case .message: return L("Message")
        }
    }

    var symbol: String {
        switch self {
        case .call: return "phone.fill"
        case .video: return "video.fill"
        case .audio: return "phone.connection.fill"   // the handset-with-signal glyph the reference frame uses
        case .message: return "message.fill"
        }
    }

    /// Nil when the contact has nothing to dial or message: the button is then dimmed and disabled.
    func url(for c: MediaContact) -> String? {
        switch self {
        case .call: return c.dialablePhone.map { "tel:\($0)" }
        case .video: return c.handle.flatMap { Self.encoded("facetime:", $0) }
        case .audio: return c.handle.flatMap { Self.encoded("facetime-audio:", $0) }
        case .message: return c.dialablePhone.map { "sms:\($0)" } ?? c.email.flatMap { Self.encoded("imessage:", $0) }
        }
    }

    /// Opens the person's card in Contacts (falls back to the app for demo / scene data).
    static func reveal(_ c: MediaContact) {
        if c.id.hasSuffix(":ABPerson"), let url = encoded("addressbook://", c.id) {
            Open.url(url)
        } else {
            Open.bundle("com.apple.AddressBook")
        }
    }

    private static func encoded(_ scheme: String, _ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).map { scheme + $0 }
    }
}

private struct MediaContactCard: View {
    let contact: MediaContact
    @Environment(\.metrics) private var m

    var body: some View {
        HStack(spacing: m.u(6.7)) {
            MediaAvatar(contact: contact, size: 46)
                .offset(y: m.u(-0.25))
                .onTapGesture { MediaContactAction.reveal(contact) }
                .help(contact.name)
            HStack(spacing: m.u(6.1)) {
                ForEach(MediaContactAction.allCases) { action in
                    MediaCallButton(action: action, url: action.url(for: contact))
                }
            }
            // The reference row sits 1.5 device px below centre; `.offset` would snap the half pixel.
            .transformEffect(CGAffineTransform(translationX: 0, y: m.u(0.75)))
        }
    }
}

/// 31 pt gradient disc with a soft glow of its own colour beneath it.
private struct MediaCallButton: View {
    @Environment(\.metrics) private var m
    @Environment(\.palette) private var p
    let action: MediaContactAction
    let url: String?

    /// Gradient (lighter top → deeper bottom), glyph size and the glyph's optical vertical nudge, in pt.
    private var look: (top: Color, bottom: Color, glyph: CGFloat, nudge: CGFloat) {
        switch action {
        case .call: return (Color(hex: "#58DA8E"), Color(hex: "#30C872"), 12.25, 0.5)
        case .video: return (Color(hex: "#5A97FD"), Color(hex: "#3C7BF9"), 12.75, 0)
        case .audio: return (Color(hex: "#6FBAFE"), Color(hex: "#4A9FF5"), 13.25, 0)
        case .message: return (Color(hex: "#9988FE"), Color(hex: "#7D6BF9"), 12.6, 0.5)
        }
    }

    var body: some View {
        let look = look
        let enabled = url != nil
        let d = m.u(31)
        let fill: AnyShapeStyle = p.monochrome
            ? AnyShapeStyle(p.controlStrong)
            : AnyShapeStyle(LinearGradient(colors: [look.top, look.bottom], startPoint: UnitPoint(x: 0.5, y: 0.1), endPoint: UnitPoint(x: 0.5, y: 0.85)))
        Button {
            if let url { Open.url(url) }
        } label: {
            Image(systemName: action.symbol)
                .font(.system(size: m.u(look.glyph), weight: .semibold))
                .offset(y: m.u(look.nudge))
                .foregroundStyle(p.monochrome ? p.primary : .white)
                .frame(width: d, height: d)
                .background {
                    Circle().fill(fill)
                        .shadow(color: p.monochrome || !enabled ? .clear : look.bottom.opacity(0.45), radius: m.u(3), y: m.u(1.5))
                }
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(action.title)
        .accessibilityLabel(action.title)
    }
}
