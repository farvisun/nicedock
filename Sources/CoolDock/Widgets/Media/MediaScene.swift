import AppKit

/// Reference-scene data for this family (see `ReferenceScene`). Returns nil for kinds it doesn't own.
///
/// The tiles read these values only while `ReferenceScene.isActive` (`--render … --scene reference`):
/// no AppleScript, Contacts or audio is touched, and live data paths are unchanged.
@MainActor
enum MediaScene {
    struct Track {
        var name: String
        var artist: String
        var artwork: NSImage?
        var isPlaying: Bool
        var duration: Double
        var position: Double
        /// The reference frame catches the title marquee mid-scroll; this freezes it there (pt).
        var titleScroll: CGFloat
    }

    private(set) static var track: Track?
    private(set) static var mail: MediaMailSnapshot?
    private(set) static var note: MediaNoteSnapshot?
    private(set) static var contacts: [MediaContact] = []

    static func prepare(_ kind: WidgetKind, _ variant: String?) -> [String: String]? {
        switch kind {
        case .nowPlaying, .nowPlayingHero:
            track = Track(name: "Evil Ways (feat. J. Cole)", artist: "Drake", artwork: ReferenceScene.asset("frame-nowplaying-artwork.png"),
                          isPlaying: false, duration: 254, position: 3, titleScroll: kind == .nowPlaying ? 38.25 : 0)
            return [:]
        case .backgroundSounds:
            return ["sound": "rain"]
        case .mail:
            mail = MediaMailSnapshot(unread: 12, today: 3, sender: "Alex Morgan", subject: "Project kickoff timeline")
            return [:]
        case .mailLatest:
            mail = MediaMailSnapshot(unread: 5, today: 2, sender: "Alex Morgan", subject: "Project kickoff timeline")
            return [:]
        case .notes:
            note = MediaNoteSnapshot(title: "Meeting notes", body: "Discuss launch timeline and assign owners for each workstream.", count: 8)
            return [:]
        case .quickContacts:
            // Portraits cut from the reference frame itself (the site doesn't publish them separately).
            let people = [("maya", "Maya Brooks", "frame-contact-1.png"),
                          ("leo", "Leo Ramos", "frame-contact-2.png"),
                          ("daniel", "Daniel Hart", "frame-contact-3.png")]
            contacts = people.map { id, name, file in
                let initials = name.split(separator: " ").compactMap(\.first).map(String.init).joined()
                return MediaContact(id: "scene-\(id)", name: name, initials: initials, phone: "+1 555 0100", email: "\(id)@example.com",
                                    thumbnail: try? Data(contentsOf: ReferenceScene.assetsURL.appendingPathComponent(file)))
            }
            return [:]
        case .contactCard:
            // Same person as the first Quick Contacts portrait; the frame shows no name, only the avatar. The portrait is
            // cut from this frame (it was resampled from the site's widget atlas at another scale), under its own id so
            // the avatar cache never hands it to Quick Contacts.
            // `contactCard-email` (no reference frame) previews the dimmed Call button of an email-only contact.
            contacts = [MediaContact(id: "scene-maya-card", name: "Maya Brooks", initials: "MB", phone: variant == "email" ? nil : "+1 555 0100",
                                     email: "maya@example.com",
                                     thumbnail: try? Data(contentsOf: ReferenceScene.assetsURL.appendingPathComponent("frame-contact-card.png")))]
            return ["contact": "scene-maya-card"]
        default:
            return nil
        }
    }
}
